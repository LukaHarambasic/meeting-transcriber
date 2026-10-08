#if !APPSTORE

    import Foundation
    import os.log

    private let logger = Logger(subsystem: AppPaths.logSubsystem, category: "ClaudeCLIProtocolGenerator")

    /// Claude CLI implementation that generates protocols via subprocess.
    struct ClaudeCLIProtocolGenerator: ProtocolGenerating {
        let claudeBin: String
        let language: String

        static let timeoutSeconds: TimeInterval = 600

        /// Search paths for Claude CLI binaries.
        static let searchPaths = [
            "\(NSHomeDirectory())/.local/bin",
            "/usr/local/bin",
            "\(NSHomeDirectory())/.npm-global/bin",
            "/opt/homebrew/bin",
        ]

        // MARK: - ProtocolGenerating

        func generate(
            transcript: String,
            title _: String,
            diarized: Bool,
            meetingStartTime: Date?,
            notes: String? = nil,
        ) async throws -> String {
            let prompt = ProtocolGenerator.buildSystemPrompt(
                diarized: diarized, language: language, meetingStartTime: meetingStartTime, notes: notes,
            ) + transcript

            let process = Process()
            let resolvedBin = Self.resolveClaudePath(claudeBin)
            process.executableURL = URL(fileURLWithPath: resolvedBin)
            process.arguments = Self.buildSubprocessArgs(claudeBin: claudeBin, resolvedBin: resolvedBin)
            process.environment = Self.buildEnvironment(
                baseEnvironment: ProcessInfo.processInfo.environment, searchPaths: Self.searchPaths,
            )

            let stdinPipe = Pipe()
            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            process.standardInput = stdinPipe
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe

            // Set terminationHandler BEFORE process.run() to avoid race
            // where the process exits before the handler is installed.
            // AsyncStream buffers the yield, so even if the process exits before
            // we iterate, the value is not lost.
            let exitStream = AsyncStream<Void> { continuation in
                process.terminationHandler = { _ in
                    continuation.yield()
                    continuation.finish()
                }
            }

            do {
                try process.run()
            } catch {
                logger.error(
                    "claude_cli_not_found bin=\(self.claudeBin, privacy: .public) resolvedPath=\(resolvedBin, privacy: .public) error=\(error.localizedDescription, privacy: .public)",
                )
                throw ProtocolError.cliNotFound(claudeBin)
            }

            // Guard against process having already exited before we awaited.
            // If the process already exited, terminationHandler may have already fired,
            // but AsyncStream buffers the yield so we won't miss it.
            // No additional check needed — AsyncStream handles the race.

            // Write stdin in a detached task to avoid deadlock on large transcripts.
            // The pipe buffer is finite (~64KB); if the prompt exceeds it, a synchronous
            // write blocks until the reader drains — but we haven't started reading yet.
            let promptData = Data(prompt.utf8)
            logger.info("claude_cli_subprocess_start prompt_bytes=\(promptData.count, privacy: .public)")
            let stdinWriteTask = Task.detached {
                // Use the throwing `write(contentsOf:)` rather than the deprecated
                // `write(_:)`: the latter raises an uncatchable Obj-C NSException on
                // a write error (e.g. EPIPE when the child's stdin read end has
                // closed — which happens on the timeout path where readStreamJSON
                // calls process.terminate()), aborting the whole app. The throwing
                // API turns a broken pipe into a handled Swift error so we can log
                // and fall through to close the handle. Mirrors the write sites in
                // RecognitionStats and PersistentDiagnosticLog.
                do {
                    try stdinPipe.fileHandleForWriting.write(contentsOf: promptData)
                } catch {
                    logger.debug(
                        "claude_cli_stdin_write_failed error=\(error.localizedDescription, privacy: .public)",
                    )
                }
                try? stdinPipe.fileHandleForWriting.close()
            }

            // Read stream-json output concurrently with stdin write
            let (text, streamFailure) = try await Self.readStreamJSON(from: stdoutPipe, process: process)

            // Ensure stdin write completes (should be done by now)
            _ = await stdinWriteTask.value

            // Read stderr in background to prevent pipe buffer issues
            async let stderrRead = Task.detached {
                stderrPipe.fileHandleForReading.readDataToEndOfFile()
            }.value

            // Await process exit via the stream installed before launch
            for await _ in exitStream {
                break
            }

            // A reported error counts even on exit 0: the CLI can print its
            // failure text as an ordinary assistant message, which would
            // otherwise be saved as the protocol.
            if process.terminationStatus != 0 || streamFailure.isError {
                let stderrData = await stderrRead
                throw Self.logAndMakeFailure(
                    exitCode: process.terminationStatus, stderrData: stderrData, streamFailure: streamFailure,
                )
            }

            return try Self.validateGeneratedText(text)
        }

        /// Log a failed run and turn it into the error to throw.
        private static func logAndMakeFailure(
            exitCode: Int32, stderrData: Data, streamFailure: StreamFailure,
        ) -> ProtocolError {
            let stderrText = String(data: stderrData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let streamReason = streamFailure.message ?? ""
            logger.error(
                "claude_cli_failed exit=\(exitCode, privacy: .public) stderr=\(stderrText, privacy: .public) result=\(streamReason, privacy: .public) auth=\(streamFailure.isAuthentication, privacy: .public)",
            )
            return makeFailureError(exitCode: exitCode, stderrText: stderrText, streamFailure: streamFailure)
        }

        /// Turn a failed run into a `ProtocolError`. An authentication failure
        /// becomes `.cliNotSignedIn`, because the fix (sign in) is not
        /// something a CLI exit code or raw stderr tells the user. Otherwise the
        /// detail is stderr, falling back to the stream's `result` text: the
        /// CLI exits 1 with EMPTY stderr and puts the reason on stdout.
        static func makeFailureError(
            exitCode: Int32,
            stderrText: String,
            streamFailure: StreamFailure = StreamFailure(),
        ) -> ProtocolError {
            if streamFailure.isAuthentication { return .cliNotSignedIn }
            let detail = stderrText.isEmpty ? (streamFailure.message ?? "") : stderrText
            return .cliFailed(Int(exitCode), detail)
        }

        /// Trim whitespace from CLI output. Throws `.emptyProtocol` when
        /// the subprocess exited successfully but produced no usable text.
        static func validateGeneratedText(_ text: String) throws -> String {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { throw ProtocolError.emptyProtocol }
            return trimmed
        }

        // MARK: - Stream JSON

        /// What the stream said about a failed run. The CLI reports its reason
        /// on stdout, as a `result` line with `is_error: true` (and, for a
        /// sign-in problem, an earlier assistant line with
        /// `"error":"authentication_failed"`), not on stderr.
        struct StreamFailure: Equatable {
            /// The `result` text of an `is_error` result line.
            var message: String?
            var isAuthentication = false
            var isError = false

            /// Fold one stream-json line in. Lines that carry no error are ignored.
            mutating func absorb(line: String) {
                guard let data = line.data(using: .utf8),
                      let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    return
                }
                let type = obj["type"] as? String
                if type == "assistant", obj["error"] as? String == "authentication_failed" {
                    isError = true
                    isAuthentication = true
                }
                if type == "result", obj["is_error"] as? Bool == true {
                    isError = true
                    let text = (obj["result"] as? String)?
                        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    if !text.isEmpty {
                        message = text
                        if Self.looksLikeAuthFailure(text) { isAuthentication = true }
                    }
                }
            }

            /// Whether an error text is the CLI saying it is not signed in.
            static func looksLikeAuthFailure(_ text: String) -> Bool {
                let lowered = text.lowercased()
                return ["authenticate", "oauth", "log in", "login"].contains { lowered.contains($0) }
            }
        }

        /// Parse Claude CLI stream-json output and accumulate text and failure info.
        private static func readStreamJSON(
            from pipe: Pipe, process: Process,
        ) async throws -> (text: String, failure: StreamFailure) {
            let handle = pipe.fileHandleForReading
            var parts: [String] = []
            var failure = StreamFailure()
            let startTime = ProcessInfo.processInfo.systemUptime

            // Read line-by-line from stdout
            var buffer = Data()
            while true {
                if ProcessInfo.processInfo.systemUptime - startTime > timeoutSeconds {
                    let elapsed = ProcessInfo.processInfo.systemUptime - startTime
                    let elapsedStr = String(format: "%.1f", elapsed)
                    logger.error(
                        "claude_cli_timeout elapsed=\(elapsedStr, privacy: .public)s parts_received=\(parts.count, privacy: .public)",
                    )
                    process.terminate()
                    throw ProtocolError.timeout
                }

                // Wrap blocking availableData in Task.detached to avoid
                // blocking Swift's cooperative thread pool. availableData blocks
                // until data is available or EOF, which would starve other tasks.
                let chunk = await Task.detached { handle.availableData }.value
                if chunk.isEmpty { break } // EOF

                buffer.append(chunk)
                parts.append(contentsOf: drainStreamJSONLines(buffer: &buffer, failure: &failure))
            }

            return (parts.joined(), failure)
        }

        /// Drain every newline-terminated line currently in `buffer`, parsing
        /// each via `parseStreamJSONLine` and folding error lines into `failure`.
        /// Returns the extracted text fragments in order. Lines that are empty after trimming, lines
        /// that don't decode as UTF-8, and lines that `parseStreamJSONLine`
        /// rejects are silently skipped.
        ///
        /// Trailing bytes without a terminating newline stay in `buffer`
        /// for the next call to consume — the caller must keep the buffer
        /// across iterations.
        static func drainStreamJSONLines(buffer: inout Data, failure: inout StreamFailure) -> [String] {
            var fragments: [String] = []
            while let newlineIdx = buffer.firstIndex(of: 0x0A) {
                let lineData = buffer[buffer.startIndex ..< newlineIdx]
                buffer.removeSubrange(buffer.startIndex ... newlineIdx)

                guard let line = String(data: lineData, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                    !line.isEmpty else { continue }

                failure.absorb(line: line)
                if let text = parseStreamJSONLine(line) {
                    fragments.append(text)
                }
            }
            return fragments
        }

        /// Parse a single stream-json line and extract text content.
        static func parseStreamJSONLine(_ line: String) -> String? {
            guard let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return nil
            }

            // content_block_delta carries streaming text chunks
            if obj["type"] as? String == "content_block_delta",
               let delta = obj["delta"] as? [String: Any],
               delta["type"] as? String == "text_delta",
               let text = delta["text"] as? String {
                return text
            }

            // assistant message carries the final full text
            if obj["type"] as? String == "assistant",
               let message = obj["message"] as? [String: Any],
               let content = message["content"] as? [[String: Any]] {
                for block in content {
                    if block["type"] as? String == "text",
                       let text = block["text"] as? String {
                        return text
                    }
                }
            }

            return nil
        }

        // MARK: - CLI Resolution

        /// Scan known install locations for executables starting with "claude".
        /// Always includes "claude" as a fallback even if not found.
        static func availableClaudeBinaries() -> [String] {
            let fm = FileManager.default
            var names = Set<String>()

            for dir in searchPaths {
                guard let entries = try? fm.contentsOfDirectory(atPath: dir) else { continue }
                for entry in entries where entry.hasPrefix("claude") {
                    let full = "\(dir)/\(entry)"
                    if fm.isExecutableFile(atPath: full) {
                        names.insert(entry)
                    }
                }
            }

            names.insert("claude")
            return names.sorted()
        }

        /// Resolve the claude CLI binary path.
        /// App bundles have a restricted PATH, so check common install locations.
        static func resolveClaudePath(_ bin: String) -> String {
            // If already an absolute path, use it
            if bin.hasPrefix("/") { return bin }

            for path in searchPaths.map({ "\($0)/\(bin)" })
                where FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
            // Fallback: hope it's in PATH
            return "/usr/bin/env"
        }

        // MARK: - Pure subprocess builders

        /// Build the CLI argument vector. When `resolvedBin` is the
        /// `/usr/bin/env` fallback, prepend `claudeBin` so env can resolve
        /// it from PATH.
        static func buildSubprocessArgs(claudeBin: String, resolvedBin: String) -> [String] {
            // `--restricted` ignores the user's own Claude settings files, so
            // their hooks cannot run inside this call. Without it a personal Stop
            // hook made the model answer it after the protocol, and that reply
            // was appended to the saved summary ("Nothing new to record from
            // this task." in 19 transcripts). It also removes the CLI's
            // command-running tools, which summarising a transcript never needs.
            var args = ["-p", "-", "--output-format", "stream-json", "--verbose", "--model", "sonnet", "--restricted"]
            if resolvedBin == "/usr/bin/env" {
                args.insert(claudeBin, at: 0)
            }
            return args
        }

        /// Strip `CLAUDECODE` (avoid nested-session detection by the child
        /// CLI) and prepend `searchPaths` to `PATH` (app bundles inherit
        /// a minimal `PATH`).
        static func buildEnvironment(
            baseEnvironment: [String: String],
            searchPaths: [String],
        ) -> [String: String] {
            var env = baseEnvironment
            env.removeValue(forKey: "CLAUDECODE")
            let extraPaths = searchPaths.joined(separator: ":")
            env["PATH"] = "\(extraPaths):\(env["PATH"] ?? "/usr/bin:/bin")"
            return env
        }
    }

#endif
