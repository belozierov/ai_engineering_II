import Foundation
import ClaudeCLI
import ClaudeDomain
import ClaudeSessions
import ClaudeTranscript

// A live integration spike against the real claude CLI. It proves four things about driving Claude
// Code as a headless agent loop, each from evidence outside the model's own narration: the session
// is hermetic (transcript shows no built-in tool ever ran), our hosted tool really executed (the
// closure recorded it in this process), a --max-turns cutoff comes back as a pause instead of a
// thrown error, and resuming after that pause still sees the pre-pause tool result (it repeats a
// nonce that only the tool result carried).
struct Spike {

	static let proxySubcommand = "tool-proxy"

	private static let maximumAttempts = 3
	private static let systemPrompt = "You are a test agent. Use the available tools when asked."
	private static let toolPrompt = """
		Do exactly this, in order:
		1. Call the fetch_incident_code tool for the service named "checkout".
		2. Then write a numbered ten-step analysis of the returned code's format — one step per \
		character group, each step at least two sentences, explaining the group's structure and how \
		you would validate it.
		Start with the tool call.
		"""
	private static let continuationPrompt = """
		Continue: report the exact incident code the fetch_incident_code tool returned, verbatim. \
		Answer with that code and nothing else. Do not call any tools.
		"""

	private let workingDirectory: URL
	private let incidentCode = UUID().uuidString
	private let callLog = IncidentCodeCallLog()

	init() throws {
		// Fresh and isolated so the session transcripts are the spike's own, and symlink-resolved
		// because claude records the resolved cwd — and the ~/.claude/projects folder name is
		// derived from it, so resolving here is what makes transcript discovery deterministic.
		let directory = URL(filePath: NSTemporaryDirectory()).appending(path: "ops-spike-\(UUID().uuidString)")
		try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
		workingDirectory = directory.resolvingSymlinksInPath()
	}

	// MARK: Run

	func run() async throws -> SpikeReport {
		// The transcripts the report points at live under ~/.claude/projects, so the working directory has
		// nothing left to say once the run is over — and leaving one behind per run is a slow leak in a
		// shared temp directory.
		defer { try? FileManager.default.removeItem(at: workingDirectory) }

		let tool = IncidentCodeTool(incidentCode: incidentCode, callLog: callLog)
		let hostedToolName = Claude.Permissions.Rule.hostedTool(named: tool.name).rawValue
		let factory = try CLISessionFactory(
			workingDirectory: workingDirectory,
			toolProxy: .subcommand(Self.proxySubcommand))
		let configuration = configuration(hosting: tool)

		log("working directory: \(workingDirectory.path(percentEncoded: false))")
		log("nonce: \(incidentCode)")
		log("hosted tool: \(hostedToolName)")

		var sessionIDs: [UUID] = []
		var attempts: [String] = []
		var lastSession: (any Claude.Session)?
		var pause: Claude.SessionResult.Pause?

		for attempt in 1...Self.maximumAttempts {
			let session = factory.create(configuration)
			sessionIDs.append(session.id)
			lastSession = session
			log("attempt \(attempt): session \(session.id.uuidString.lowercased()) — sending the tool prompt")

			let outcome: String
			do {
				let result = try await session.send(Self.toolPrompt)
				pause = result.pause
				outcome = describe(result)
			} catch {
				outcome = "threw \(error)"
			}

			attempts.append("attempt \(attempt): \(outcome)")
			log("attempt \(attempt): \(outcome)")
			guard pause == nil else { break }
		}

		// Resumed even when nothing paused: a completed first send is already a criterion-3 failure,
		// and the continuation still tells us whether resume carries the pre-cutoff tool result.
		var continuation = ""
		var continuationOutcome = "not attempted"
		if let lastSession {
			log("resuming session \(lastSession.id.uuidString.lowercased()) — sending the continuation prompt")
			do {
				let result = try await lastSession.send(Self.continuationPrompt)
				continuation = result.output
				continuationOutcome = describe(result)
			} catch {
				continuationOutcome = "threw \(error)"
			}
			log("continuation: \(continuationOutcome)")
		}

		let scan = scan(sessionIDs)
		let foreignToolNames = scan.toolNames.subtracting([hostedToolName])
		let services = await callLog.services

		var report = SpikeReport()
		report.record(
			"Hermetic session — no built-in tool or tool search in any transcript",
			isPassing: !scan.paths.isEmpty && scan.missing.isEmpty && scan.failures.isEmpty && foreignToolNames.isEmpty,
			detail: """
				tool_use names observed: \(list(scan.toolNames)); foreign names: \(list(foreignToolNames)); \
				transcripts scanned: \(scan.paths.count)/\(sessionIDs.count)\
				\(scan.failures.isEmpty ? "" : "; read failures: \(scan.failures.joined(separator: ", "))")
				""")
		report.record(
			"Hosted tool really ran — recorded inside the tool closure, in this process",
			isPassing: !services.isEmpty,
			detail: "closure invocations: \(services.count) (service=\(list(services)))")
		report.record(
			"Max-turns cutoff is a returned pause, not a thrown error",
			isPassing: pause?.terminalReason == "max_turns",
			detail: pause.map {
				"pause.terminalReason=\($0.terminalReason ?? "nil"), numTurns=\($0.numTurns.map(String.init) ?? "nil")"
			} ?? "no pause after \(attempts.count) attempt(s)")
		report.record(
			"Resume keeps pre-pause context — repeats the nonce only the tool result carried",
			isPassing: continuation.range(of: incidentCode, options: .caseInsensitive) != nil,
			detail: "continuation \(continuationOutcome)")

		report.notes = ["nonce: \(incidentCode)", "working directory: \(workingDirectory.path(percentEncoded: false))"]
			+ attempts
			+ ["continuation output: \(continuation.excerpt())"]
			+ sessionIDs.map { "session: \($0.uuidString.lowercased())" }
			+ scan.missing.map { "transcript MISSING for session \($0.uuidString.lowercased())" }
			+ scan.paths.map { "transcript: \($0.path(percentEncoded: false))" }

		return report
	}

	// MARK: Configuration

	private func configuration(hosting tool: IncidentCodeTool) -> Claude.SessionConfiguration {
		var features = Claude.Features.default
		// toolSearch is the load-bearing removal: left on, MCP tools are reachable only behind a
		// deferred lookup the model must perform first, and a one-turn session never gets that far.
		// The rest keep the session from inheriting this machine's context and settings.
		features.subtract([
			.toolSearch,
			.projectInstructions,
			.autoMemory,
			.inheritedSettings,
			.externalMCPServers,
			.autoCompaction,
			.slashCommands
		])

		// `tools: []` renders `--tools ""` — every built-in removed. Nil would mean "all of them".
		return Claude.SessionConfiguration(
			model: .haiku,
			systemPrompt: Self.systemPrompt,
			tools: [],
			maxTurns: 1,
			hostedTools: [tool],
			permissions: Claude.Permissions(allow: [.hostedTool(named: tool.name)], isBypassingChecks: true),
			features: features,
			requestTimeout: .seconds(180))
	}

	// MARK: Transcripts

	private struct Scan {

		var paths: [URL] = []
		var missing: [UUID] = []
		var toolNames: Set<String> = []
		var failures: [String] = []
	}

	// Tree-scoped lookup first (the session ran in the temp working directory), then unscoped as a
	// fallback — the projects folder name is a lossy encoding of the cwd, so a miss there is not
	// proof the transcript is gone.
	private func scan(_ sessionIDs: [UUID]) -> Scan {
		let projects = ClaudeProjectsDirectory()
		var scan = Scan()

		for sessionID in sessionIDs {
			let url = projects.transcriptURL(for: sessionID, inTreeRootedAt: workingDirectory)
				?? projects.transcriptURL(for: sessionID)
			guard let url else {
				scan.missing.append(sessionID)
				continue
			}

			scan.paths.append(url)
			do {
				let transcript = try Transcript(contentsOf: url)
				scan.toolNames.formUnion(transcript.records.flatMap { $0.message?.toolUses ?? [] }.compactMap(\.name))
			} catch {
				scan.failures.append("\(url.lastPathComponent): \(error)")
			}
		}

		return scan
	}

	// MARK: Reporting

	private func describe(_ result: Claude.SessionResult) -> String {
		guard let pause = result.pause else {
			return "completed without a pause, output: \(result.output.excerpt())"
		}

		return """
			paused (terminalReason=\(pause.terminalReason ?? "nil"), numTurns=\(pause.numTurns.map(String.init) ?? "nil")\
			\(pause.errors.isEmpty ? "" : ", errors=\(pause.errors.joined(separator: " | ").excerpt())")), \
			output: \(result.output.excerpt())
			"""
	}

	private func list(_ values: some Collection<String>) -> String {
		values.isEmpty ? "<none>" : values.sorted().joined(separator: ", ")
	}

	private func log(_ message: String) {
		print("ops-spike: \(message)")
	}
}
