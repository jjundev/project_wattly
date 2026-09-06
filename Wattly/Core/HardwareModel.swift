import Darwin

func currentHardwareModel() -> String {
    var size = 0
    sysctlbyname("hw.model", nil, &size, nil, 0)
    guard size > 0 else { return "" }
    var buffer = [CChar](repeating: 0, count: size)
    sysctlbyname("hw.model", &buffer, &size, nil, 0)
    return String(cString: buffer)
}

func currentProcessorName() -> String {
    var size = 0
    guard sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0) == 0, size > 0 else { return "" }
    var buffer = [CChar](repeating: 0, count: size)
    guard sysctlbyname("machdep.cpu.brand_string", &buffer, &size, nil, 0) == 0 else { return "" }
    return String(cString: buffer).trimmingCharacters(in: .whitespacesAndNewlines)
}
