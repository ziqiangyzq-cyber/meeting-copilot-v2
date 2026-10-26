import Foundation

@main
struct SpeechCoreChecks {
    static func main() {
        let suite = SpeechCoreTests()
        let checks: [(String, () throws -> Void)] = [
            ("Code point slice combining marks and bounds", suite.testCodePointSliceAndBounds),
            ("Declared request metadata core validation", suite.testDeclaredRequestMetadataValidatedInCore),
            ("Audio file stream final and retained overlap guard", suite.testAudioFileStreamFinalAndOverlapGuard),
            ("Unknown stream kinds rejected atomically", suite.testUnknownStreamKindsRejectedAtomically),
            ("Chunk metadata duplicate and overlap validation", suite.testChunkMetadataDuplicatesAndOverlappingFrames),
            ("JSON Unicode and unknown speaker", suite.testJSONRoundTripUnknownSpeakerAndUnicodeText),
            ("Out-of-order replay equivalence and duplicate", suite.testOutOfOrderAndDuplicateMatchOrderedBaseline),
            ("Partial gate and corrected source invalidation", suite.testPartialCannotTranslateThenCorrectionInvalidatesTranslation),
            ("Late source response and nonblocking new request", suite.testOldSourceResponseCannotBlockNewRequestOrConsumeRevision),
            ("Superseded request and duplicate response", suite.testSameSourceSupersededRequestAndRepeatedResponseDiscarded),
            ("Glossary invalidation", suite.testGlossaryRevisionInvalidatesPendingResponse),
            ("Contiguous publication revisions and ID binding", suite.testSecondPublicationRevisionIsContiguousAndBound),
            ("Gap resume, channel independence, running rejection", suite.testGapResumeDoesNotProveRunningAndOtherChannelIndependent),
            ("Unknown gap and repeated closure", suite.testUnknownGapAndRepeatedCloseRejectedAtomically),
            ("Poison event freeze and terminal recovery", suite.testIllegalRevisionFreezesWithoutReplayingPoisonForever),
            ("Authority replay recovery", suite.testAuthoritativeReplayRecoveryMatchesBaselineAndInvalidatesRequests),
            ("Atomic checkpoint rejection and request generation", suite.testInvalidCheckpointAtomicAndPostRestoreRequestGenerationIncreases),
            ("Buffer count bytes and monotonic timeout bounds", suite.testBufferCountBytesAndTimeoutBounds),
            ("Envelope conflict clock and configuration rejection", suite.testMalformedEnvelopeSequenceConflictAndNonMonotonicClock)
        ]
        var passed = 0
        for (name, check) in checks {
            let before = suite.failures
            do { try check() } catch { suite.failures += 1; print("FAIL \(name): \(error)") }
            if suite.failures == before { passed += 1; print("PASS \(name)") }
        }
        print("RESULT: \(passed)/\(checks.count) checks passed; \(suite.failures) failures; synthetic data only")
        exit(suite.failures == 0 ? 0 : 1)
    }
}
