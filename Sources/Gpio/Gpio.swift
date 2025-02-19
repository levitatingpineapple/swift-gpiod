import Foundation
import gpiod

public actor Gpio {
	public enum Error: Swift.Error {
		case chipNotFound
		case lineNotFound
		case lineRequestFailed
		case unableToSetValue
		case unableToGetValue
		case waitError
		case waitTimeout
		case malformedEvent
	}

	enum EventType: Int32 {
		case risingEdge = 1
		case fallingEdge
	}

	public enum WaitResult: Int32, Sendable {
		case error = -1
		case timeout
		case event
	}

	static let consumer = "swift-gpio"
	private let chip: OpaquePointer
	private var lines = Dictionary<UInt32, OpaquePointer>()

	public init(_ name: String) throws {
		guard let chip = gpiod_chip_open_by_name(name) else {
			throw Error.chipNotFound
		}
		self.chip = chip
	}

	public func set(gpio offset: UInt32, to value: Bool) throws {
		try handle(
			gpiod_line_set_value(outputLine(at: offset), value ? 1 : 0),
			with: .unableToSetValue
		)
	}

	public func stream(gpio offset: UInt32) throws -> AsyncStream<Bool> {
		AsyncStream { continuation in
			do {
				let line = try streamLine(at: offset)
				DispatchQueue.global().async {
					while true {
						do {
							switch WaitResult(rawValue: gpiod_line_event_wait(line, nil)) {
							case .error: throw Error.waitError
							case .timeout: throw Error.waitTimeout
							case .event:
								var event = gpiod_line_event()
								try handle(
									gpiod_line_event_read(line, &event),
									with: .malformedEvent
								)
								switch EventType(rawValue: event.event_type) {
									case .risingEdge: continuation.yield(true)
									case .fallingEdge: continuation.yield(false)
									case nil: throw Error.malformedEvent
								}
							case nil: throw Error.malformedEvent
							}
						} catch {
							fatalError("Gpio streaming error: \(error)")
						}
					}
				}
			} catch {
				print(error)
			}
		}
	}

	private func line(
		at offset: UInt32,
		request: (OpaquePointer) throws -> Int32
	) throws -> OpaquePointer {
		try lines[offset] ?? {
			guard let line = gpiod_chip_get_line(chip, offset) else {
				throw Error.lineNotFound
			}
			try handle(request(line), with: .lineRequestFailed)
			lines[offset] = line
			return line
		}()
	}

	private func outputLine(at offset: UInt32) throws -> OpaquePointer {
		try line(at: offset) { line in
			gpiod_line_request_output_flags(
				line,
				Self.consumer,
				Int32(GPIOD_LINE_REQUEST_FLAG_ACTIVE_LOW),
				.zero
			)
		}
	}

	private func inputLine(at offset: UInt32) throws -> OpaquePointer {
		try line(at: offset) { line in
			gpiod_line_request_input_flags(
				line,
				Self.consumer,
				Int32(GPIOD_LINE_REQUEST_FLAG_BIAS_PULL_UP)
			)
		}
	}

	private func streamLine(at offset: UInt32) throws -> OpaquePointer {
		try line(at: offset) { line in
			gpiod_line_request_both_edges_events(
				line,
				Self.consumer
			)
		}
	}
	
}

private func handle(_ ret: Int32, with gpioError: Gpio.Error) throws {
	switch ret {
	case 0: return
	case -1: throw gpioError
	default: fatalError("Unexpected return value \(ret)")
	}
}

extension OpaquePointer: @retroactive @unchecked Sendable { }
