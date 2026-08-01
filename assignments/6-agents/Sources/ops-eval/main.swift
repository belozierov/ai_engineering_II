import Foundation
import OpsEval

// The authoritative evaluator as a binary: one report on stdout — human by default, `--json` on request —
// and the report's own exit code, which is 0 only when every required core result was observed and every
// one of them passed. Run `ops-eval --help` for the flags and the workspace default.
exit(await EvaluationConsole().run(arguments: Array(CommandLine.arguments.dropFirst())))
