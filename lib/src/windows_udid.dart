import "dart:convert";
import "dart:io";
import "package:crypto/crypto.dart";
import "package:logging/logging.dart";

/// Unity-compatible Windows UDID implementation
/// Replicates Unity's SystemInfo.deviceUniqueIdentifier for Windows Standalone
class WindowsUDID {
  WindowsUDID._privateConstructor();

  static String? _uniqueId;
  static final _logger = Logger("flutter_udid");

  /// Returns a stable unique ID.
  /// Priority:
  /// 1. Legacy WMIC (backward-compatible with old devices)
  /// 2. Unity-compatible PowerShell implementation
  /// 3. MachineGuid registry (final fallback)
  static Future<String> uniqueIdentifier() async {
    if (_uniqueId != null && _uniqueId!.isNotEmpty) {
      return _uniqueId!;
    }

    // --- OLD IMPLEMENTATION (wmic) ---
    final legacyId = await _legacyIdentifier();
    if (legacyId.isNotEmpty) {
      _logger.info("Using legacy UDID (backward-compatible).");
      _uniqueId = legacyId;
      return _uniqueId!;
    }

    // --- NEW IMPLEMENTATION (PowerShell/Unity style) ---
    final unityId = await _unityIdentifier();
    if (unityId.isNotEmpty) {
      _logger.info("Using Unity-compatible UDID (new).");
      _uniqueId = unityId;
      return _uniqueId!;
    }

    // --- FINAL FALLBACK: MachineGuid ---
    final guid = await _machineGuidFallback();
    _logger.warning(
        "Both legacy & Unity UDID failed. Using MachineGuid fallback.");
    _uniqueId = guid;
    return _uniqueId!;
  }

  /// Original implementation (matches bb0ad9... style IDs).
  static Future<String> _legacyIdentifier() async {
    try {
      final baseBoardID = await _fetchWinID(
          "wmic", ["baseboard", "get", "serialnumber"], "serialnumber");
      final biosID =
          await _fetchWinID("wmic", ["csproduct", "get", "uuid"], "uuid");
      final processorID = await _fetchWinID(
          "wmic", ["cpu", "get", "processorid"], "processorid");
      final diskDriveID = await _fetchWinID(
          "wmic", ["diskdrive", "get", "serialnumber"], "serialnumber");
      final osNumber = await _fetchWinID(
          "wmic", ["os", "get", "serialnumber"], "serialnumber");

      final all = baseBoardID + biosID + processorID + diskDriveID + osNumber;
      if (all.isNotEmpty) {
        return sha256.convert(utf8.encode(all)).toString();
      }
    } catch (e) {
      _logger.warning("Legacy WMIC UDID failed: $e");
    }
    return "";
  }

  /// New implementation (Unity-like, PowerShell).
  // Exact same hardware classes as Unity, but using modern PowerShell
  static Future<String> _unityIdentifier() async {
    final baseBoardID = await _queryWMI("Win32_BaseBoard", "SerialNumber");
    final biosID = await _queryWMI("Win32_ComputerSystemProduct", "UUID");
    final processorID =
        await _queryWMI("Win32_Processor", "ProcessorId", selectFirst: true);
    final diskDriveID = await _runPowerShellQuery(
        "Get-CimInstance Win32_DiskDrive | Where-Object {\$_.MediaType -eq 'Fixed hard disk media'} | Select-Object -First 1 -ExpandProperty SerialNumber -ErrorAction SilentlyContinue");
    final osNumber = await _queryWMI("Win32_OperatingSystem", "SerialNumber");

    final all = baseBoardID + biosID + processorID + diskDriveID + osNumber;
    if (all.isNotEmpty) {
      return sha256.convert(utf8.encode(all)).toString();
    }
    return "";
  }

  /// Final fallback: MachineGuid from registry
  static Future<String> _machineGuidFallback() async {
    try {
      final result = await Process.run(
        "reg",
        ["query", r"HKLM\SOFTWARE\Microsoft\Cryptography", "/v", "MachineGuid"],
        runInShell: true,
      );

      if (result.exitCode == 0) {
        final output = result.stdout.toString();
        final match = RegExp(r"MachineGuid\s+REG_SZ\s+([a-fA-F0-9\-]+)")
            .firstMatch(output);
        if (match != null) {
          return sha256.convert(utf8.encode(match.group(1)!)).toString();
        }
      }
    } catch (e) {
      _logger.warning("MachineGuid fallback failed: $e");
    }
    // As absolute last resort: random UUID (not recommended for persistence)
    return sha256
        .convert(utf8.encode(DateTime.now().toIso8601String()))
        .toString();
  }

  // --- Helpers for legacy ---
  static Future<String> _fetchWinID(
      String executable, List<String> arguments, String regExpSource) async {
    String id = "";
    try {
      final process = await Process.start(executable, arguments,
          mode: ProcessStartMode.detachedWithStdio);
      final result = await process.stdout.transform(utf8.decoder).toList();
      for (var element in result) {
        final item = element.toLowerCase().replaceAll(
              RegExp("\r|\n|\\s|$regExpSource"),
              "",
            );
        if (item.isNotEmpty) id += item;
      }
    } catch (_) {}
    return id;
  }

  // --- Helpers for new ---
  static Future<String> _queryWMI(String className, String property,
      {bool selectFirst = false}) async {
    final command = selectFirst
        ? "Get-CimInstance $className | Select-Object -First 1 -ExpandProperty $property -ErrorAction SilentlyContinue"
        : "Get-CimInstance $className | Select-Object -ExpandProperty $property -ErrorAction SilentlyContinue";

    return _runPowerShellQuery(command);
  }

  /// Run PowerShell command and return cleaned output
  static Future<String> _runPowerShellQuery(String command) async {
    try {
      final result = await Process.run(
        "powershell",
        ["-NoProfile", "-Command", command],
        runInShell: true,
      );

      if (result.exitCode == 0) {
        String output = result.stdout.toString().trim();

        // Clean the output similar to original code, but more carefully
        output = output
            .replaceAll('\r', '')
            .replaceAll('\n', ' ')
            .replaceAll(RegExp(r'\s+'), ' ') // Multiple spaces to single space
            .trim();

        // Filter out common placeholder/empty values
        if (output.isNotEmpty &&
            !output.toLowerCase().contains('to be filled') &&
            !output.toLowerCase().contains('not available') &&
            !output.toLowerCase().contains('not applicable') &&
            !output.toLowerCase().contains('none') &&
            output != '0' &&
            output != 'null') {
          return output;
        }
      }
    } catch (e) {
      _logger.warning("PowerShell WMI query failed: $command, Error: $e");
    }
    return "";
  }
}
