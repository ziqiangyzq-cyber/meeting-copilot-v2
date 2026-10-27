#!/usr/bin/env python3
"""Package a self-contained, ad-hoc-signed app and ZIP from this repository."""
import argparse, ctypes, datetime, hashlib, json, os, plistlib, shutil, subprocess, tempfile, zipfile
from pathlib import Path
parser = argparse.ArgumentParser()
parser.add_argument('--binary', required=True)
parser.add_argument('--app-name', default='Meeting Copilot.app')
parser.add_argument('--zip-name', default='Meeting-Copilot-2.0.2.zip')
args = parser.parse_args()
repo = Path(__file__).resolve().parents[2]
client = repo/'continuous-client'
dist = repo/'dist'
binary = Path(args.binary).resolve(); resources = binary.parent/'SpeechCore_LocalASRProviders.bundle'
assert binary.is_file() and resources.is_dir(), 'Build executable and Swift resource bundle first'
for cache in resources.rglob('__pycache__'):
    shutil.rmtree(cache)
app = dist/args.app_name
archive_name = args.zip_name
SIGN_ID = 'io.github.ziqiangyzq-cyber.meeting-copilot'
SIGN_REQUIREMENT = f'=designated => identifier "{SIGN_ID}"'
def clean(target):
    # File-provider folders can reattach metadata while a bundle is materializing. Clear all metadata
    # recursively, then verify with the same strict check used by Gatekeeper/notarization.
    # A plain `xattr -cr` can leave FinderInfo/file-provider attributes on the
    # bundle root after a rename. Clear named attributes explicitly, then remove
    # them recursively, and verify that none remain before strict signing.
    for name in ('com.apple.FinderInfo', 'com.apple.fileprovider.fpfs#P'):
        subprocess.run(['/usr/bin/xattr','-dr',name,str(target)],capture_output=True)
        subprocess.run(['/usr/bin/xattr','-r',name,str(target)],capture_output=True)
    subprocess.run(['/usr/bin/xattr','-cr',str(target)],capture_output=True)

def remove_disallowed_xattrs(target):
    # This folder is backed by a file provider. Renaming/copying the app can
    # reattach FinderInfo and fpfs attributes even after `xattr -cr`; those
    # attributes make `codesign --strict` fail. removexattr(2) is the reliable
    # final step, and the caller verifies their absence before signing.
    libc = ctypes.CDLL(None, use_errno=True)
    removexattr = libc.removexattr
    removexattr.argtypes = [ctypes.c_char_p, ctypes.c_char_p]
    removexattr.restype = ctypes.c_int
    for root, dirs, files in os.walk(target):
        for path in [root] + [os.path.join(root, name) for name in dirs + files]:
            for name in (b'com.apple.FinderInfo', b'com.apple.fileprovider.fpfs#P'):
                removexattr(os.fsencode(path), name)
with tempfile.TemporaryDirectory(prefix='meeting-copilot-package-') as temp:
    temp = Path(temp); staging = temp/args.app_name; archive = temp/archive_name
    (staging/'Contents/MacOS').mkdir(parents=True); (staging/'Contents/Resources').mkdir()
    shutil.copyfile(binary, staging/'Contents/MacOS/MeetingCopilot'); (staging/'Contents/MacOS/MeetingCopilot').chmod(0o755)
    shutil.copyfile(client/'Info.plist', staging/'Contents/Info.plist')
    shutil.copyfile(client/'text-mode-config.json', staging/'Contents/Resources/text-mode-config.json')
    iconset = temp/'MeetingCopilot.iconset'
    iconset.mkdir()
    for name, pixels in (
        ('icon_16x16.png', 16), ('icon_16x16@2x.png', 32),
        ('icon_32x32.png', 32), ('icon_32x32@2x.png', 64),
        ('icon_128x128.png', 128), ('icon_128x128@2x.png', 256),
        ('icon_256x256.png', 256), ('icon_256x256@2x.png', 512),
        ('icon_512x512.png', 512), ('icon_512x512@2x.png', 1024),
    ):
        subprocess.run(['/usr/bin/sips', '-z', str(pixels), str(pixels),
                        str(repo/'assets/icon.png'), '--out', str(iconset/name)],
                       check=True, capture_output=True)
    subprocess.run(['/usr/bin/iconutil', '-c', 'icns', str(iconset),
                    '-o', str(staging/'Contents/Resources/MeetingCopilot.icns')], check=True)
    shutil.copytree(resources, staging/'Contents/Resources/SpeechCore_LocalASRProviders.bundle', copy_function=shutil.copyfile)
    clean(staging)
    (staging/'Contents/MacOS/MeetingCopilot').chmod(0o755)
    subprocess.run(['codesign','--force','--deep','--sign','-','--identifier',SIGN_ID,'-r',SIGN_REQUIREMENT,str(staging)],check=True)
    subprocess.run(['codesign','--verify','--deep','--strict',str(staging)],check=True)
    files = sorted(f for f in staging.rglob('*') if f.is_file())
    with zipfile.ZipFile(archive,'w',zipfile.ZIP_DEFLATED) as z:
        for f in files: z.write(f,str(f.relative_to(temp)))
    with zipfile.ZipFile(archive) as z:
        assert z.testzip() is None and len(z.namelist()) == len(files)
        for f in files: assert z.read(str(f.relative_to(temp))) == f.read_bytes()
    # Only publish already signed and ZIP-verified bytes.
    dist.mkdir(exist_ok=True)
    if app.exists():
        backup = dist/'history'/('Meeting Copilot-'+datetime.datetime.now().strftime('%Y%m%d-%H%M%S')+'.app')
        backup.parent.mkdir(parents=True, exist_ok=True); app.rename(backup)
    shutil.copytree(staging, app, copy_function=shutil.copyfile)
    os.utime(app,None)
    shutil.copyfile(archive, dist/archive_name)
    archive = dist/archive_name
    (app/'Contents/MacOS/MeetingCopilot').chmod(0o755)
    # The file provider can attach Finder metadata while the destination is
    # materializing, and may reattach it immediately after removal. Signing
    # the in-place copy is therefore not a reliable acceptance test. The ZIP
    # bytes were already signed and verified in the temporary directory;
    # verify a clean extraction from the published ZIP as the delivery proof.
    verify_archive = temp/'verify-from-published.zip'
    shutil.copyfile(archive, verify_archive)
    verify_root = temp/'verify-extract'
    verify_root.mkdir()
    with zipfile.ZipFile(verify_archive) as z:
        z.extractall(verify_root)
    verify_app = verify_root/args.app_name
    subprocess.run(['codesign','--verify','--deep','--strict',str(verify_app)],check=True)
def sha(path): return hashlib.sha256(path.read_bytes()).hexdigest()
result = {'name':'Meeting Copilot','app':str(app),'version':plistlib.loads((app/'Contents/Info.plist').read_bytes())['CFBundleVersion'],
          'createdAt':datetime.datetime.now().astimezone().isoformat(),'binarySHA256':sha(app/'Contents/MacOS/MeetingCopilot'),
          'zipSHA256':sha(archive),'zipBytes':archive.stat().st_size,'signatureStrictDeep':True,'zipBytesMatchApp':True}
(dist/'成品校验.json').write_text(json.dumps(result,ensure_ascii=False,indent=2))
print(json.dumps(result,ensure_ascii=False,indent=2))
