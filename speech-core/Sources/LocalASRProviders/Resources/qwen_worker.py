"""Bounded NDJSON local batch worker. stdout contains protocol only; no mic/network/download."""
import os, sys, json, pathlib, hashlib, time, traceback, socket, contextlib, subprocess, tempfile
os.environ['HF_HUB_OFFLINE'] = '1'
os.environ['TOKENIZERS_PARALLELISM'] = 'false'
os.environ['PYTHONDONTWRITEBYTECODE'] = '1'
os.environ['HF_HOME'] = str(pathlib.Path(tempfile.gettempdir())/'meeting-copilot-qwen-offline-cache')
class NoOutboundSocket(socket.socket):
    def connect(self, address): raise RuntimeError('INFERENCE_NETWORK_DISABLED')
    def connect_ex(self, address): raise RuntimeError('INFERENCE_NETWORK_DISABLED')
socket.socket = NoOutboundSocket
PROTOCOL = 1
REVISION = 'e1f6c266914abc5a46e8756e02580f834a6cf8a7'
BACKEND = '7f8b420ad4188c6a2be038ba8e24d9f00cfedb72'
WEIGHT_SHA = '2f080a3b769ae469aeaaa2dcb9e13a94141e54c9e6d5a7aa63392e0dc5a51789'

def digest(path):
    h = hashlib.sha256()
    with path.open('rb') as f:
        for block in iter(lambda:f.read(8*1024*1024), b''): h.update(block)
    return h.hexdigest()

def send(reply):
    reply.update(protocol=PROTOCOL,workerPID=os.getpid())
    sys.__stdout__.write(json.dumps(reply,ensure_ascii=False,allow_nan=False)+'\n'); sys.__stdout__.flush()

def fail(request_id, error):
    send({'id':request_id,'type':'error','error':str(error),'errorType':type(error).__name__})

try:
    model_dir, manifest_path, reference_dir = map(pathlib.Path, sys.argv[1:4])
    load_context = json.loads(sys.argv[4])
    if load_context is not None and (not isinstance(load_context,str) or len(load_context.encode('utf-8')) > 4096): raise RuntimeError('CONTEXT_UTF8_LIMIT_4096')
    if sys.platform != 'darwin' or os.uname().machine != 'arm64': raise RuntimeError('MAC_ARM64_REQUIRED')
    import platform
    if int(platform.mac_ver()[0].split('.')[0]) < 26: raise RuntimeError('MACOS_26_REQUIRED_FOR_PINNED_RUNTIME')
    if not all(p.is_absolute() for p in [model_dir,manifest_path,reference_dir]): raise RuntimeError('ABSOLUTE_PATH_REQUIRED')
    import fcntl
    gpu_lease = open(pathlib.Path(tempfile.gettempdir())/('meeting-copilot-qwen-'+str(os.getuid())+'.gpu.lock'),'a')
    try: fcntl.flock(gpu_lease.fileno(),fcntl.LOCK_EX|fcntl.LOCK_NB)
    except BlockingIOError: raise RuntimeError('QWEN_GPU_BUSY')
    if digest(manifest_path) != '31008ea5e0a636f3051afcd94d2c1b1183f32afc03ec23f7c5e63e898e692dd3': raise RuntimeError('PINNED_MANIFEST_SHA_MISMATCH')
    manifest = json.loads(manifest_path.read_text())
    if manifest['revision'] != REVISION or manifest['repo'] != 'mlx-community/Qwen3-ASR-1.7B-bf16': raise RuntimeError('MODEL_REVISION_UNSUPPORTED')
    files = manifest['files']
    weight = next(x for x in files if x['path']=='model.safetensors')
    if weight['sha256'] != WEIGHT_SHA or weight['bytes'] != 4076186653: raise RuntimeError('MODEL_MANIFEST_NOT_PINNED')
    for item in files:
        relative = pathlib.Path(item['path'])
        if relative.is_absolute() or '..' in relative.parts: raise RuntimeError('INVALID_ASSET_PATH')
        path = model_dir/relative
        if not path.is_file() or path.stat().st_size != item['bytes'] or digest(path) != item['sha256']: raise RuntimeError('MODEL_ASSET_SHA_MISMATCH:'+str(relative))
    actual_commit = subprocess.check_output(['/usr/bin/git','-C',str(reference_dir),'rev-parse','HEAD'],text=True).strip()
    if actual_commit != BACKEND: raise RuntimeError('BACKEND_REVISION_MISMATCH')
    import importlib.metadata as md
    with contextlib.redirect_stdout(sys.stderr):
        import mlx.core as mx
        import soundfile as sf
        import qwen3_asr_mlx
        from qwen3_asr_mlx import Qwen3ASR
        import qwen3_asr_mlx.model as model_module
        from qwen3_asr_mlx.tokenizer import EOS_TOKEN_IDS
        installed = pathlib.Path(qwen3_asr_mlx.__file__).parent
        expected_source = reference_dir/'src/qwen3_asr_mlx'
        source_hashes = {}
        for path in sorted(expected_source.glob('*.py')):
            sha = digest(path)
            if digest(installed/path.name) != sha: raise RuntimeError('INSTALLED_BACKEND_SOURCE_MISMATCH:'+path.name)
            # Verify reference working tree against the pinned git blob, not merely installed equality.
            blob = subprocess.check_output(['/usr/bin/git','-C',str(reference_dir),'show',BACKEND+':src/qwen3_asr_mlx/'+path.name])
            if hashlib.sha256(blob).hexdigest() != sha: raise RuntimeError('REFERENCE_SOURCE_MODIFIED:'+path.name)
            source_hashes[path.name] = sha
        if len(source_hashes) != 8 or md.version('qwen3-asr-mlx') != '0.2.0' or md.version('mlx') != '0.32.3': raise RuntimeError('PINNED_RUNTIME_MISMATCH')
        started = time.monotonic()
        model = Qwen3ASR.from_pretrained(model_dir)
        mx.synchronize()
        if load_context is not None and len(model._tokenizer.encode(load_context)) > 128: raise RuntimeError('CONTEXT_TOKEN_LIMIT_128')
        load_seconds = time.monotonic()-started
    engine = 'qwen3-asr-mlx/'+md.version('qwen3-asr-mlx')+';mlx='+md.version('mlx')+';backend='+actual_commit+';frontend=community;mode=file-batch;bridge=1'
    model_version = manifest['repo']+'@'+manifest['revision']
    send({'id':'load','type':'loaded','engineVersion':engine,'modelVersion':model_version,'loadSeconds':load_seconds,'device':str(mx.default_device()),'sourceHashes':source_hashes})
except BaseException as e:
    traceback.print_exc(file=sys.stderr); fail('load',e); sys.exit(2)

original_generate = model_module.generate
for line in sys.stdin:
    request_id = 'unknown'
    try:
        if len(line) > 16384: raise RuntimeError('REQUEST_TOO_LARGE')
        request = json.loads(line); request_id = request['id']
        if request.get('protocol') != PROTOCOL or request.get('command') != 'transcribe': raise RuntimeError('INVALID_REQUEST')
        source = pathlib.Path(request['filePath'])
        if not source.is_absolute() or not source.is_file() or source.stat().st_size > 40000000: raise RuntimeError('INVALID_AUDIO_FILE')
        audio_sha = digest(source)
        info = sf.info(str(source))
        if info.frames <= 0 or info.channels != 1 or info.samplerate != 16000 or not 0 < info.duration <= 8: raise RuntimeError('AUDIO_REQUIRES_MONO_16K_MAX_8_SECONDS')
        context = request.get('context',load_context)
        if context != load_context: raise RuntimeError('CONTEXT_CHANGED_RELOAD_REQUIRED')
        if context is not None and (not isinstance(context,str) or len(context.encode('utf-8')) > 4096): raise RuntimeError('CONTEXT_UTF8_LIMIT_4096')
        if context is not None and len(model._tokenizer.encode(context)) > 128: raise RuntimeError('CONTEXT_TOKEN_LIMIT_128')
        import numpy as np
        pcm, sample_rate = sf.read(str(source),dtype='float32',always_2d=False)
        if sample_rate != 16000 or pcm.ndim != 1 or pcm.size != info.frames or not np.isfinite(pcm).all(): raise RuntimeError('INVALID_PCM_NONFINITE_OR_FORMAT')
        if digest(source) != audio_sha: raise RuntimeError('AUDIO_CHANGED_DURING_READ')
        if request.get('expectedAudioSHA256') and request['expectedAudioSHA256'] != audio_sha: raise RuntimeError('AUDIO_SHA_MISMATCH')
        generations = []
        def observed_generate(*args, **kwargs):
            ids = original_generate(*args,**kwargs)
            generations.append({'tokenIDs':ids,'endedWithEOS':bool(ids and ids[-1] in EOS_TOKEN_IDS),'rawDecoded':model._tokenizer.decode(ids,skip_special_tokens=False)})
            return ids
        model_module.generate = observed_generate
        with contextlib.redirect_stdout(sys.stderr):
            started = time.monotonic()
            result = model.transcribe(pcm,temperature=0.0,max_tokens=256,language=None,context=context,chunk_duration=1200.0)
            mx.synchronize(); elapsed = time.monotonic()-started
        # Include raw evidence even for a semantic final failure.
        reply = {'id':request_id,'type':'final','text':result.text,'language':result.language,'duration':result.duration,'elapsedSeconds':elapsed,'audioSHA256':audio_sha,'generations':generations,'engineVersion':engine,'modelVersion':model_version,'context':context,'peakMLXBytes':mx.get_peak_memory()}
        if digest(source) != audio_sha: reply.update(type='error',error='AUDIO_CHANGED_DURING_INFERENCE')
        elif not generations or not all(g['endedWithEOS'] for g in generations): reply.update(type='error',error='DECODE_NOT_TERMINATED_WITH_EOS')
        elif not result.text.strip(): reply.update(type='error',error='EMPTY_TRANSCRIPT')
        send(reply)
    except BaseException as e:
        traceback.print_exc(file=sys.stderr); fail(request_id,e)
    finally:
        model_module.generate = original_generate
model.close()
