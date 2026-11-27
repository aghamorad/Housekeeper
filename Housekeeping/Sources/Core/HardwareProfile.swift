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

    static var isIntel: Bool { !isAppleSilicon }

    /// Compiler/mach architecture name (`arm64` or `x86_64`).
    static var archName: String {
        isAppleSilicon ? "arm64" : "x86_64"
    }

    /// Plain words for the screen. "Intel" is the word a reader recognises;
    /// "x86_64" is the word a compiler recognises.
    static var kind: String {
        isAppleSilicon ? "Apple silicon" : "Intel"
    }

    /// Friendly full label for settings and setup screens.
    static var displayLabel: String {
        isAppleSilicon ? "Apple Silicon (arm64)" : "Intel Mac (x86_64)"
    }

    /// The Homebrew prefix for this Mac's native architecture.
    static var preferredHomebrewPrefix: String {
        isAppleSilicon ? "/opt/homebrew" : "/usr/local"
    }

    /// Homebrew bin/sbin folders ordered so this Mac's native architecture is
    /// always found first (preventing an Intel Mac from picking up a migrated
    /// Apple-Silicon-only `/opt/homebrew/bin` binary).
    static var orderedHomebrewBinPaths: [String] {
        if isAppleSilicon {
            return ["/opt/homebrew/bin", "/opt/homebrew/sbin", "/usr/local/bin", "/usr/local/sbin"]
        }
        return ["/usr/local/bin", "/usr/local/sbin", "/opt/homebrew/bin", "/opt/homebrew/sbin"]
    }

    /// Housekeeper ships a universal (Intel + Apple Silicon) `ffmpeg` and
    /// `ffprobe` inside its Bookbind runtime. MediaDock and other tools can
    /// fall back to it automatically without needing Homebrew installed first.
    static var bundledUniversalBinPath: String? {
        guard let url = Bundle.main.resourceURL?
            .appendingPathComponent("Bookbind", isDirectory: true)
            .appendingPathComponent("bin", isDirectory: true) else {
            return nil
        }
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
            return url.path
        }
        return nil
    }

    /// Checks whether a Mach-O executable or script can actually run on this Mac.
    /// Returns `false` when an Intel Mac encounters an `arm64`-only binary
    /// (e.g. copied over from an Apple Silicon Mac in `/opt/homebrew/bin`),
    /// which would otherwise fail with "Bad CPU type in executable".
    static func isExecutableCompatibleWithCurrentArch(_ path: String) -> Bool {
        architectureMismatchDetail(for: path) == nil
    }

    /// Returns a plain-language reason if an executable cannot run on this Mac's
    /// CPU, or `nil` when it is compatible (script, universal binary, or matching slice).
    static func architectureMismatchDetail(for path: String) -> String? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        let header = handle.readData(ofLength: 8)
        guard header.count >= 8 else { return nil }

        // Scripts (#!) are executed by their interpreter.
        if header[0] == 0x23 && header[1] == 0x21 { return nil }

        let magic = header.withUnsafeBytes { $0.load(as: UInt32.self) }
        // Universal (fat) binaries contain multiple slices (usually arm64 + x86_64).
        if magic == 0xBEBAFECA || magic == 0xCAFEBABE || magic == 0xBFBAFECA || magic == 0xCAFEBABF {
            return nil
        }
        // 64-bit Mach-O little-endian (MH_MAGIC_64 = 0xFEEDFACF).
        if magic == 0xFEEDFACF {
            let cpuType = header.withUnsafeBytes { $0.load(fromByteOffset: 4, as: UInt32.self) }
            let cpuTypeArm64: UInt32 = 0x0100000C
            if isIntel && cpuType == cpuTypeArm64 {
                return "Apple Silicon only (arm64) — cannot run on this Intel Mac."
            }
        }
        return nil
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

    /// One-line Homebrew + tools setup command tailored to this Mac's chip.
    static var mediaDockQuickSetupCommand: String {
        if isIntel {
            return #"eval "$(/usr/local/bin/brew shellenv)" 2>/dev/null; brew install yt-dlp deno pipx && pipx ensurepath && pipx install spotdl && pipx install gamdl"#
        }
        return #"eval "$(/opt/homebrew/bin/brew shellenv)" 2>/dev/null; brew install yt-dlp deno pipx && pipx ensurepath && pipx install spotdl && pipx install gamdl"#
    }
}
