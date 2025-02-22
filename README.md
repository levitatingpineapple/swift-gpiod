# Minimal Swift bindings for [libgpiod](https://libgpiod.readthedocs.io/en/latest/index.html)

Tested on RaspberryPi 4 running library version 1.6.3

## Install

```bash
sudo apt update
sudo apt install -y libgpiod-dev gpiod
```

## Usage

```swift
import Foundation
import AsyncAlgorithms
import Gpio

// Initialize the chip
let chip = try Gpio("gpiodchip0")

// Setting output value
try await chip.set(
	gpio: 15,
	to: true,
	flags: [.activeLow]
)

// Reading input value
let value: Bool = try await chip.get(
	gpio: 16,
	flags: [.pullUp]
)
print(value)

// Continuously monitoring a pin
let stream = try await chip
	.stream(gpio: 17)
	.debounce(for: .milliseconds(50))
	.removeDuplicates()

for await value in stream {
	print("Sreaming \(value)")
}

```
