// Housekeeping — what kind of Mac this is
//
// The app is one universal binary, so the same build runs on an M-series laptop
// and on an Intel desktop. Some features are not merely slower on one of them,
// they do not exist: MLX is Apple-silicon only, and Metal offload in llama.cpp
// has no Intel backend. Asking an Intel Mac to use either is not a slow path,
// it is a download followed by a failure — which is exactly what it used to do.
//
// One place answers the question, so no screen has to guess.

import Foundation

enum HardwareProfile {

    /// True on M1/M2/M3/M4 and later. False on every Intel Mac, and also false
    /// if the app is ever run through Rosetta, where the safe answer is the CPU.
    static let isAppleSilicon: Bool = {
        var info = utsname()
        guard uname(&info) == 0 else { return false }
        let machine = withUnsafeBytes(of: &info.machine) { raw -> String in
            let bytes = raw.prefix { $0 != 0 }
            return String(decoding: bytes, as: UTF8.self)
        }
        return machine == "arm64"
    }()

    /// Plain words for the screen. "Intel" is the word a reader recognises;
    /// "x86_64" is the word a compiler recognises.
    static var kind: String {
        isAppleSilicon ? "Apple silicon" : "Intel"
    }

    /// How Housekeeper's own model should be run here.
    static var localModelAdvice: String {
        if isAppleSilicon {
            return "Runs on this Mac's graphics chip, which is fast for small models."
        }
        return "This Intel Mac runs the model on its processor. It works — it is just slower, so pick the smallest model and expect a short wait for the first answer."
    }

    /// Why a runtime cannot be offered at all, or nil when it can.
    static var mlxUnavailableReason: String? {
        isAppleSilicon ? nil :
            "MLX is Apple-silicon only. It cannot load on this Intel Mac. Housekeeper's own model (the Qwen/Gemma GGUF choices in Settings) does run here, on the processor."
    }
}
