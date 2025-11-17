# srslog - Logging Framework Documentation

## Overview

srslog is a high-performance, thread-safe logging framework designed for srsRAN applications. It provides a flexible logging system with support for multiple log levels, various output sinks (stdout, stderr, files, syslog, UDP), and customizable formatters (text, contextual text, JSON).

## Key Features

- **Thread-safe**: All logging operations are thread-safe
- **Asynchronous**: Log entries are processed by a background worker thread
- **Multiple log levels**: Error, Warning, Info, Debug
- **Flexible sinks**: stdout, stderr, files, syslog, UDP sockets
- **Customizable formatters**: Plain text, contextual text, JSON
- **Context support**: Optional context values (two 32-bit integers) for log entries
- **Hex dump support**: Built-in support for logging binary data

## Quick Start

### 1. Initialize the Framework

Before using any logging functionality, you must initialize the framework:

```cpp
#include "srsran/srslog/srslog.h"

int main() {
    // Initialize the logging framework
    srslog::init();
    
    // Your application code here
    
    return 0;
}
```

### 2. Create a Logger

The most common way to create a logger is using `fetch_basic_logger`:

```cpp
#include "srsran/srslog/srslog.h"

auto& logger = srslog::fetch_basic_logger("MY_COMPONENT");
```

### 3. Log Messages

```cpp
// Log at different levels
logger.error("Error occurred: {}", error_message);
logger.warning("Warning: {}", warning_message);
logger.info("Information: {}", info_message);
logger.debug("Debug info: {}", debug_message);
```

## Detailed Usage

### Initialization

The `init()` function starts the logging backend worker thread. You can specify the priority of the backend thread:

```cpp
// Normal priority (default)
srslog::init();

// High priority
srslog::init(srslog::backend_priority::high);

// Low priority
srslog::init(srslog::backend_priority::low);
```

**Important**: `init()` must be called before generating any log entries. Calling it multiple times has no side effects.

### Basic Logger

A `basic_logger` provides four log levels:
- `error` (highest priority)
- `warning`
- `info`
- `debug` (lowest priority)

#### Creating a Basic Logger

```cpp
// Create logger with default sink (stdout)
auto& logger = srslog::fetch_basic_logger("COMPONENT_NAME");

// Create logger with context printing enabled
auto& logger = srslog::fetch_basic_logger("COMPONENT_NAME", true);

// Create logger with custom sink
auto& file_sink = srslog::fetch_file_sink("/path/to/logfile.log");
auto& logger = srslog::fetch_basic_logger("COMPONENT_NAME", file_sink);
```

#### Setting Log Levels

```cpp
auto& logger = srslog::fetch_basic_logger("MY_COMPONENT");

// Set to specific level
logger.set_level(srslog::basic_levels::info);  // Shows error, warning, info
logger.set_level(srslog::basic_levels::debug); // Shows all levels
logger.set_level(srslog::basic_levels::error); // Shows only errors
logger.set_level(srslog::basic_levels::none);  // Disables all logging

// Convert string to level
if (auto level = srslog::str_to_basic_level("INFO")) {
    logger.set_level(*level);
}
```

#### Logging with Context

You can set context values (two 32-bit integers) that will be included in log entries:

```cpp
// Set context for all channels in the logger
logger.set_context(sfn, slot_index);

// Or log with inline context
logger.info(sfn, slot_index, "Processing slot: sfn={}, slot={}", sfn, slot_index);
```

#### Logging Binary Data

```cpp
uint8_t buffer[1024];
size_t buffer_len = 1024;

// Log binary data as hex dump
logger.debug(buffer, buffer_len, "Received packet: {} bytes", buffer_len);

// Set maximum hex dump size
logger.set_hex_dump_max_size(256);  // Limit to 256 bytes
logger.set_hex_dump_max_size(-1);   // No limit
```

### Sinks

Sinks define where log entries are written. The framework supports several sink types:

#### Default Sink

By default, loggers write to stdout. You can change the default sink:

```cpp
auto& file_sink = srslog::fetch_file_sink("/var/log/app.log");
srslog::set_default_sink(file_sink);
srslog::init();
```

#### Stdout Sink

```cpp
// Get default stdout sink
auto& stdout_sink = srslog::fetch_stdout_sink();

// Create custom stdout sink with specific formatter
auto formatter = srslog::create_json_formatter();
auto& custom_stdout = srslog::fetch_stdout_sink("my_stdout", std::move(formatter));
```

#### Stderr Sink

```cpp
// Get default stderr sink
auto& stderr_sink = srslog::fetch_stderr_sink();

// Create custom stderr sink
auto& custom_stderr = srslog::fetch_stderr_sink("my_stderr");
```

#### File Sink

```cpp
// Basic file sink
auto& file_sink = srslog::fetch_file_sink("/var/log/app.log");

// File sink with rotation (creates new file when size exceeds max_size)
auto& rotating_sink = srslog::fetch_file_sink("/var/log/app.log", 10 * 1024 * 1024); // 10 MB

// File sink with custom options
auto& custom_file = srslog::fetch_file_sink(
    "/var/log/app.log",
    10 * 1024 * 1024,  // max_size: 10 MB
    true,               // mark_eof: add end mark when closed
    true,               // force_flush: flush after every write
    srslog::create_json_formatter()  // custom formatter
);
```

#### Syslog Sink

```cpp
// Basic syslog sink
auto& syslog_sink = srslog::fetch_syslog_sink();

// Custom syslog sink
auto& custom_syslog = srslog::fetch_syslog_sink(
    "my_app",                                    // preamble/ident
    srslog::syslog_local_type::local1,          // facility
    srslog::create_text_formatter()             // formatter
);
```

#### UDP Sink

```cpp
// Send logs to remote UDP server
auto& udp_sink = srslog::fetch_udp_sink(
    "192.168.1.100",              // remote IP
    514,                          // port
    srslog::create_json_formatter()  // formatter
);
```

#### Finding Existing Sinks

```cpp
// Find a sink by ID
if (auto* sink = srslog::find_sink("my_sink")) {
    // Use the sink
}
```

### Formatters

Formatters control how log entries are formatted before being written to sinks.

#### Available Formatters

```cpp
// Plain text formatter (no context)
auto text_fmt = srslog::create_text_formatter();

// Contextual text formatter (includes context values)
auto contextual_fmt = srslog::create_contextual_text_formatter();

// JSON formatter
auto json_fmt = srslog::create_json_formatter();
```

#### Setting Default Formatter

```cpp
// Set default formatter for new sinks
srslog::set_default_log_formatter(srslog::create_json_formatter());
```

### Log Channels

For more fine-grained control, you can work directly with log channels:

```cpp
// Fetch a log channel
auto& channel = srslog::fetch_log_channel("MY_CHANNEL");

// Configure channel
srslog::log_channel_config config;
config.name = "MyChannel";
config.tag = 'M';
config.should_print_context = true;

auto& configured_channel = srslog::fetch_log_channel("MY_CHANNEL", config);

// Use the channel
channel("Log message: {}", value);

// Enable/disable channel
channel.set_enabled(false);  // Disable
channel.set_enabled(true);   // Enable

// Check if enabled
if (channel.enabled()) {
    channel("This will be logged");
}
```

### Custom Loggers

You can create custom logger types with different log levels:

```cpp
// 1. Define the log level enum
enum class my_logger_levels { none, error, warning, info, LAST };

// 2. Define the channel structure
struct my_logger_channels {
    srslog::log_channel& error;
    srslog::log_channel& warning;
    srslog::log_channel& info;
};

// 3. Create the logger type
using my_logger = srslog::build_logger_type<my_logger_channels, my_logger_levels>;

// 4. Create logger instances
auto& error_ch = srslog::fetch_log_channel("MY_ERROR");
auto& warning_ch = srslog::fetch_log_channel("MY_WARNING");
auto& info_ch = srslog::fetch_log_channel("MY_INFO");

auto& custom_logger = srslog::fetch_logger<my_logger>(
    "MY_LOGGER",
    error_ch,
    warning_ch,
    info_ch
);

// Use the custom logger
custom_logger.error("Error message");
custom_logger.warning("Warning message");
custom_logger.info("Info message");
```

### Framework Control

#### Flushing Logs

Force all sinks to flush their contents:

```cpp
srslog::flush();  // Blocks until all sinks are flushed
```

#### Error Handling

Set a custom error handler to receive framework error messages:

```cpp
srslog::set_error_handler([](const std::string& error_msg) {
    // Handle error
    std::cerr << "srslog error: " << error_msg << std::endl;
});

// Must be called before init()
srslog::init();
```

## Complete Example

```cpp
#include "srsran/srslog/srslog.h"
#include <iostream>

int main() {
    // Set up error handler
    srslog::set_error_handler([](const std::string& msg) {
        std::cerr << "srslog error: " << msg << std::endl;
    });

    // Create file sink with rotation
    auto& file_sink = srslog::fetch_file_sink(
        "/var/log/myapp.log",
        10 * 1024 * 1024,  // 10 MB rotation
        true,               // mark_eof
        false,              // force_flush
        srslog::create_contextual_text_formatter()
    );

    // Set as default sink
    srslog::set_default_sink(file_sink);

    // Initialize framework
    srslog::init();

    // Create logger
    auto& logger = srslog::fetch_basic_logger("MYAPP", true);

    // Configure logger
    logger.set_level(srslog::basic_levels::debug);
    logger.set_hex_dump_max_size(256);

    // Set context
    logger.set_context(0, 0);

    // Log messages
    logger.error("Application started");
    logger.warning("Low memory detected");
    logger.info("Processing request {}", 12345);
    logger.debug("Debug information: value={}", 42);

    // Log with inline context
    logger.info(100, 5, "Processing slot sfn={}, slot={}", 100, 5);

    // Log binary data
    uint8_t data[] = {0x01, 0x02, 0x03, 0x04};
    logger.debug(data, sizeof(data), "Received data: {} bytes", sizeof(data));

    // Flush before exit
    srslog::flush();

    return 0;
}
```

## Best Practices

1. **Initialize early**: Call `srslog::init()` as early as possible in your application, ideally in `main()` before any other logging calls.

2. **Use meaningful logger IDs**: Use descriptive IDs that identify the component or module:
   ```cpp
   auto& logger = srslog::fetch_basic_logger("PHY");      // Good
   auto& logger = srslog::fetch_basic_logger("L1");      // Good
   auto& logger = srslog::fetch_basic_logger("LOGGER");   // Not descriptive
   ```

3. **Set appropriate log levels**: Use the appropriate log level for each message:
   - `error`: Critical errors that require immediate attention
   - `warning`: Warnings about potential issues
   - `info`: General informational messages
   - `debug`: Detailed debugging information

4. **Use context for time-sensitive logs**: For logs that need timing information (like slot processing), use context values:
   ```cpp
   logger.info(sfn, slot_index, "Processing slot");
   ```

5. **Limit hex dumps in production**: Set reasonable hex dump limits to avoid performance issues:
   ```cpp
   logger.set_hex_dump_max_size(256);  // Limit to 256 bytes
   ```

6. **Flush before exit**: Always call `srslog::flush()` before application termination to ensure all logs are written.

7. **Reuse loggers**: The `fetch_basic_logger()` function returns a reference to a singleton logger. You can safely call it multiple times with the same ID to get the same logger instance.

## Thread Safety

All srslog operations are thread-safe:
- Multiple threads can create loggers simultaneously
- Multiple threads can log to the same logger simultaneously
- Log entries from different threads are processed asynchronously by the backend worker thread

## Performance Considerations

- Logging is asynchronous: log calls return immediately after queuing the entry
- Disabled log channels have minimal overhead (just an atomic check)
- The backend worker thread processes log entries in batches for efficiency
- Use appropriate log levels in production to minimize overhead

## API Reference

For detailed API documentation, see the header files:
- `include/srsran/srslog/srslog.h` - Main API
- `include/srsran/srslog/logger.h` - Logger types
- `include/srsran/srslog/log_channel.h` - Log channel API
- `include/srsran/srslog/sink.h` - Sink interface

## C API

srslog also provides a C API for C applications. See `include/srsran/srslog/srslog_c.h` for details.

