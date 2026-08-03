import Foundation
import MCP
import OpsAgent
import OpsCore
import Testing

@Suite("Planning tool over MCP")
struct WriteTodosToolTests {

	// MARK: Declaration

	@Test
	func theHostDeclaresThePlanningToolEagerly() async throws {
		let fixture = try PlanFixture()

		try await AgentDispatch.withTools([fixture.tool]) { client in
			let (tools, _) = try await client.listTools()
			let declaration = try #require(tools.first)

			#expect(tools.map(\.name) == ["write_todos"])
			// The hermetic session removes ToolSearch, so a lazily-loaded tool would be unreachable.
			#expect(declaration._meta?["anthropic/alwaysLoad"]?.boolValue == true)

			let properties = declaration.inputSchema.objectValue?["properties"]?.objectValue
			#expect(properties?.keys.sorted() == ["todos"])
			#expect(declaration.inputSchema.objectValue?["required"]?.arrayValue?.compactMap(\.stringValue) == ["todos"])
			// Nothing in the schema names identity, thread or run: whose plan this is stays injected.
			#expect(properties?.keys.contains { $0.contains("identity") || $0.contains("run") } == false)
		}
	}

	// MARK: Snapshots

	@Test
	func aValidPlanEmitsOneMetadataOnlyEvent() async throws {
		let fixture = try PlanFixture()

		let output = try await AgentDispatch.withTools([fixture.tool]) { client in
			try await client.planOutput(PlanFixture.todos(
				("Check the checkout logs", "in_progress"),
				("Correlate with monitoring", "pending")
			))
		}

		#expect(output == "Plan recorded: 2 items.")

		let events = try await fixture.events()
		let event = try #require(events.first)

		#expect(events.count == 1)
		#expect(event.eventType == .planSnapshot)
		#expect(event.status == .completed)
		#expect(event.count == 2)
		#expect(event.artifactID == "plan-test-1")
		// The digest is the only trace of what the plan says; no item text reaches the stream.
		#expect(event.digest?.count == 64)
	}

	@Test
	func repeatingTheSamePlanEmitsNothingFurther() async throws {
		let fixture = try PlanFixture()
		let todos = PlanFixture.todos(("Check the checkout logs", "in_progress"))

		let outputs = try await AgentDispatch.withTools([fixture.tool]) { client in
			[try await client.planOutput(todos), try await client.planOutput(todos)]
		}

		#expect(outputs == ["Plan recorded: 1 item.", "Plan unchanged: 1 item."])
		#expect(try await fixture.events().count == 1)
	}

	@Test
	func aChangedPlanEmitsASecondEvent() async throws {
		let fixture = try PlanFixture()

		try await AgentDispatch.withTools([fixture.tool]) { client in
			_ = try await client.planOutput(PlanFixture.todos(("Check the checkout logs", "in_progress")))
			_ = try await client.planOutput(PlanFixture.todos(("Check the checkout logs", "completed")))
		}

		let events = try await fixture.events()

		#expect(events.count == 2)
		#expect(events.map(\.artifactID) == ["plan-test-1", "plan-test-2"])
		#expect(events[0].digest != events[1].digest)
	}

	@Test
	func planEventsAreScopedToTheRunThatProducedThem() async throws {
		let fixture = try PlanFixture()

		try await AgentDispatch.withTools([fixture.tool]) { client in
			_ = try await client.planOutput(PlanFixture.todos(("Check the checkout logs", "pending")))
		}

		let foreign = try RuntimeContext(
			identityID: "identity-test-other",
			threadID: "thread-test-plan",
			runID: "run-test-plan"
		)

		#expect(try await fixture.events().count == 1)
		#expect(try await fixture.sink.events(for: foreign).isEmpty)
	}

	// MARK: Ledger

	@Test
	func theLedgerHoldsTheLatestAcceptedPlanForTheLoopToRead() async throws {
		let fixture = try PlanFixture()

		try await AgentDispatch.withTools([fixture.tool]) { client in
			_ = try await client.planOutput(PlanFixture.todos(("Check the checkout logs", "in_progress")))
			_ = try await client.planOutput(PlanFixture.todos(
				("Check the checkout logs", "completed"),
				("Read the tax-service runbook", "in_progress")
			))
		}

		let plan = await fixture.plan()

		#expect(plan.map(\.text) == ["Check the checkout logs", "Read the tax-service runbook"])
		#expect(plan.map(\.state) == [.completed, .inProgress])
		// Another run of the same identity reads nothing: the ledger is keyed by the trusted context.
		let foreign = try RuntimeContext(
			identityID: "identity-test-plan",
			threadID: "thread-test-plan",
			runID: "run-test-other"
		)

		#expect(await fixture.ledger.todos(for: foreign).isEmpty)
	}

	@Test
	func aRejectedPlanLeavesTheLedgerAlone() async throws {
		let fixture = try PlanFixture()

		try await AgentDispatch.withTools([fixture.tool]) { client in
			_ = try await client.planOutput(PlanFixture.todos(("Check the checkout logs", "pending")))
			_ = try await client.planFailure(["todos": PlanFixture.todos(("Sneak a step in", "done"))])
		}

		#expect(await fixture.plan().map(\.text) == ["Check the checkout logs"])
		#expect(try await fixture.events().count == 1)
	}

	// MARK: Malformed calls

	@Test
	func anUnknownStateComesBackAsAToolError() async throws {
		let fixture = try PlanFixture()

		let message = try await AgentDispatch.withTools([fixture.tool]) { client in
			try await client.planFailure(["todos": PlanFixture.todos(("Check the checkout logs", "almost"))])
		}

		#expect(message.contains("pending, in_progress or completed"))
		#expect(try await fixture.events().isEmpty)
	}

	@Test
	func anEmptyOrOversizedPlanComesBackAsAToolError() async throws {
		let fixture = try PlanFixture()
		let oversized = Value.array((0...WriteTodosTool.maximumTodos).map {
			.object(["text": .string("Step \($0)"), "state": .string("pending")])
		})

		let messages = try await AgentDispatch.withTools([fixture.tool]) { client in
			[
				try await client.planFailure(["todos": .array([])]),
				try await client.planFailure(["todos": oversized])
			]
		}

		#expect(messages.allSatisfy { $0.contains("between 1 and 20 items") })
		#expect(try await fixture.events().isEmpty)
	}

	@Test
	func aMisshapenArgumentComesBackAsAToolError() async throws {
		let fixture = try PlanFixture()

		let messages = try await AgentDispatch.withTools([fixture.tool]) { client in
			[
				try await client.planFailure([:]),
				try await client.planFailure(["todos": .string("check the logs")]),
				try await client.planFailure(["todos": .array([.object(["text": .string("no state given")])])])
			]
		}

		#expect(messages.allSatisfy { $0.hasPrefix("Error:") })
		#expect(try await fixture.events().isEmpty)
	}

	@Test
	func unboundedItemTextComesBackAsAToolError() async throws {
		let fixture = try PlanFixture()
		let overlong = String(repeating: "a", count: PlanSnapshotTracker.TodoItem.maximumTextLength + 1)

		let message = try await AgentDispatch.withTools([fixture.tool]) { client in
			try await client.planFailure(["todos": PlanFixture.todos((overlong, "pending"))])
		}

		#expect(message.contains("plan item"))
		#expect(try await fixture.events().isEmpty)
	}
}
