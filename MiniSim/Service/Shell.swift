import Foundation
import ShellOut

protocol ShellProtocol {
    @discardableResult func execute(
        command: String,
        arguments: [String],
        atPath: String
    ) throws -> String
}

extension ShellProtocol {
    @discardableResult func execute(
        command: String,
        arguments: [String] = [],
        atPath: String = "."
    ) throws -> String {
        try execute(command: command, arguments: arguments, atPath: atPath)
    }
}

final class Shell: ShellProtocol {
    static func escapeShellArgument(_ argument: String) -> String {
        if argument.isEmpty {
            return "''"
        }
        let escaped = argument.replacingOccurrences(of: "'", with: "'\"'\"'")
        return "'\(escaped)'"
    }

    @discardableResult func execute(
        command: String,
        arguments: [String] = [],
        atPath: String = "."
    ) throws -> String {
        let commandWithArguments: String
        if arguments.isEmpty {
            commandWithArguments = command
        } else {
            let escapedArguments = arguments.map(Self.escapeShellArgument).joined(separator: " ")
            commandWithArguments = "\(command) \(escapedArguments)"
        }

        return try shellOut(
            to: commandWithArguments,
            at: atPath
        )
    }
}
