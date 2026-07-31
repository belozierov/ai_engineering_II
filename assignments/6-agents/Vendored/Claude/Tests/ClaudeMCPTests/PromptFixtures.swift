import Foundation
import ClaudeDomain

extension Claude.HostedPrompt {

	static func greeting() -> Claude.HostedPrompt {
		Claude.HostedPrompt(
			name: "greeting",
			description: "Greets a person",
			arguments: [
				.init(name: "name", description: "Who to greet", required: true),
				.init(name: "tone", description: "Tone of the greeting", required: false)
			]) { arguments in
				let name = arguments["name"] ?? ""
				let tone = arguments["tone"].map { " (\($0))" } ?? ""
				return [
					.init(role: .user, text: "Say hello to \(name)\(tone)"),
					.init(role: .assistant, text: "Hello, \(name)!")
				]
			}
	}

	static func summarize() -> Claude.HostedPrompt {
		Claude.HostedPrompt(name: "summarize", description: "Summarizes the current context") { _ in
			[.init(role: .user, text: "Summarize the discussion so far")]
		}
	}

}
