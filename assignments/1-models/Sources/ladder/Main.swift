import HW1Core

@main
struct LadderApp {

    static func main() async throws {
        try await Homework.runLadder()
    }
}
