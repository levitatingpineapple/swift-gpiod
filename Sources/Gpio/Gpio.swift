import Foundation
import gpiod

public actor Gpio {
	public struct RequestFlags: OptionSet, Sendable {
		public let rawValue: Int32

		public init(rawValue: Int32) {
			self.rawValue = rawValue
		}

		private init(_ flag: Int) {
			self.rawValue = Int32(flag)
		}

		public static let openDrain   = Self(GPIOD_LINE_REQUEST_FLAG_OPEN_DRAIN)
		public static let openSource  = Self(GPIOD_LINE_REQUEST_FLAG_OPEN_SOURCE)
		public static let activeLow   = Self(GPIOD_LINE_REQUEST_FLAG_ACTIVE_LOW)
		public static let biasDisable = Self(GPIOD_LINE_REQUEST_FLAG_BIAS_DISABLE)
		public static let pullDown    = Self(GPIOD_LINE_REQUEST_FLAG_BIAS_PULL_DOWN)
		public static let pullUp      = Self(GPIOD_LINE_REQUEST_FLAG_BIAS_PULL_UP)
	}

	public enum Err: Error {
		case chipNotFound
		case lineNotFound
		case lineRequestFailed
		case unableToSetValue
		case unableToGetValue
		case waitError
		case waitTimeout
		case unableToReadEvent
		case unexpectedReturnValue
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
			throw Err.chipNotFound
		}
		self.chip = chip
	}

	public func set(gpio offset: UInt32, to value: Bool, flags: RequestFlags = []) throws {
		try handle(
			gpiod_line_set_value(
				line(at: offset) { line in
					gpiod_line_request_output_flags(
						line,
						Self.consumer,
						flags.rawValue,
						0
					)
				},
				value ? 1 : 0
			),
			with: .unableToSetValue
		)
	}

	public func get(gpio offset: UInt32, flags: RequestFlags = []) throws -> Bool {
		switch try gpiod_line_get_value(
			line(at: offset) { line in
				gpiod_line_request_input_flags(
					line,
					Self.consumer,
					flags.rawValue
				)
			}
		) {
		case -1: throw Err.unableToGetValue
		case 0: false
		case 1: true
		default: throw Err.unexpectedReturnValue
		}
	}
	

	public func stream(gpio offset: UInt32, flags: RequestFlags = []) throws -> AsyncStream<Bool> {
		AsyncStream { continuation in
			do {
				let line = try line(at: offset) { line in
					gpiod_line_request_both_edges_events_flags(
						line,
						Self.consumer,
						flags.rawValue
					)
				}
				// Yield initial value
				switch gpiod_line_get_value(line) {
				case -1: throw Err.unableToGetValue
				case 0: continuation.yield(false)
				case 1: continuation.yield(true)
				default: throw Err.unexpectedReturnValue
				}
				DispatchQueue.global().async {
					while true {
						do {
							switch WaitResult(rawValue: gpiod_line_event_wait(line, nil)) {
							case .error: throw Err.waitError
							case .timeout: throw Err.waitTimeout
							case .event:
								var event = gpiod_line_event()
								try handle(
									gpiod_line_event_read(line, &event),
									with: .unableToReadEvent
								)
								switch EventType(rawValue: event.event_type) {
									case .risingEdge: continuation.yield(true)
									case .fallingEdge: continuation.yield(false)
									case nil: throw Err.unexpectedReturnValue
								}
							case nil: throw Err.unexpectedReturnValue
							}
						} catch {
							fatalError("Gpio streaming error: \(error)")
						}
					}
				}
			} catch {
				print("Stream Error: \(error)")
			}
		}
	}

	private func line(
		at offset: UInt32,
		request: (OpaquePointer) throws -> Int32
	) throws -> OpaquePointer {
		try lines[offset] ?? {
			guard let line = gpiod_chip_get_line(chip, offset) else {
				throw Err.lineNotFound
			}
			try handle(request(line), with: .lineRequestFailed)
			lines[offset] = line
			return line
		}()
	}
}

private func handle(_ ret: Int32, with gpioError: Gpio.Err) throws {
	switch ret {
	case -1: throw gpioError
	case 0: return
	default: throw Gpio.Err.unexpectedReturnValue
	}
}

// `gpiod_line_event_wait` is a blocking call and requires spawning a separate thread
// to avoid locking up the stream
extension OpaquePointer: @retroactive @unchecked Sendable { }
