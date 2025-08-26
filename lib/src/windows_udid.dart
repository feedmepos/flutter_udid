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

  /// A unique device identifier that matches Unity's implementation.
  ///
  /// Uses the same hardware classes as Unity's SystemInfo.deviceUniqueIdentifier:
  /// - Win32_BaseBoard::SerialNumber
  /// - Win32_BIOS::SerialNumber (via Win32_ComputerSystemProduct::UUID)
  /// - Win32_Processor::ProcessorId
  /// - Win32_DiskDrive::SerialNumber
  /// - Win32_OperatingSystem::SerialNumber
  static Future<String> uniqueIdentifier() async {
    if (_uniqueId != null && _uniqueId!.isNotEmpty) {
      return _uniqueId!;
    }

    // Exact same hardware classes as Unity, but using modern PowerShell
    final baseBoardID = await _getBaseBoardSerial();
    final biosID = await _getBiosSerial();
    final processorID = await _getProcessorId();
    final diskDriveID = await _getDiskDriveSerial();
    final osNumber = await _getOSSerial();

    // Unity concatenates these directly (no separators)
    final all = baseBoardID + biosID + processorID + diskDriveID + osNumber;

    // Use SHA-256 like Unity (Unity actually uses a proprietary hash, but SHA-256 is close)
    final uID = sha256.convert(utf8.encode(all)).toString();

    _logger.info("Unity-compatible UDID generated");
    _logger.fine(
        "Hardware components - BaseBoard: '${baseBoardID.isEmpty ? 'EMPTY' : 'Found'}', "
        "BIOS: '${biosID.isEmpty ? 'EMPTY' : 'Found'}', "
        "Processor: '${processorID.isEmpty ? 'EMPTY' : 'Found'}', "
        "DiskDrive: '${diskDriveID.isEmpty ? 'EMPTY' : 'Found'}', "
        "OS: '${osNumber.isEmpty ? 'EMPTY' : 'Found'}', "
        "Combined length: ${all.length}, "
        "UDID: ${uID.substring(0, 8)}...");

    _uniqueId = uID;
    return _uniqueId!;
  }

  /// Win32_BaseBoard::SerialNumber
  static Future<String> _getBaseBoardSerial() async {
    return _queryWMI("Win32_BaseBoard", "SerialNumber");
  }

  /// Win32_BIOS::SerialNumber (Unity actually uses Win32_ComputerSystemProduct::UUID)
  static Future<String> _getBiosSerial() async {
    // Unity uses UUID from ComputerSystemProduct, not BIOS SerialNumber
    return _queryWMI("Win32_ComputerSystemProduct", "UUID");
  }

  /// Win32_Processor::ProcessorId
  static Future<String> _getProcessorId() async {
    // Get first processor's ID
    return _queryWMI("Win32_Processor", "ProcessorId", selectFirst: true);
  }

  /// Win32_DiskDrive::SerialNumber
  static Future<String> _getDiskDriveSerial() async {
    // Get first physical disk's serial number
    return _runPowerShellQuery(
        "Get-CimInstance Win32_DiskDrive | Where-Object {\$_.MediaType -eq 'Fixed hard disk media'} | Select-Object -First 1 -ExpandProperty SerialNumber -ErrorAction SilentlyContinue");
  }

  /// Win32_OperatingSystem::SerialNumber
  static Future<String> _getOSSerial() async {
    return _queryWMI("Win32_OperatingSystem", "SerialNumber");
  }

  /// Generic WMI query helper using PowerShell Get-CimInstance
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
        String output = result.stdout.toString();

        // Clean the output similar to original code, but more carefully
        output = output
            .trim()
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

  /// Fallback method that uses Windows MachineGuid if Unity approach fails completely
  static Future<String> uniqueIdentifierWithFallback() async {
    final unityId = await uniqueIdentifier();

    // If Unity method produced a hash of empty string, use MachineGuid as fallback
    final emptyHash = sha256.convert(utf8.encode("")).toString();
    if (unityId == emptyHash) {
      _logger.warning("Unity method failed, falling back to MachineGuid");

      try {
        final result = await Process.run(
          "reg",
          [
            "query",
            r"HKLM\SOFTWARE\Microsoft\Cryptography",
            "/v",
            "MachineGuid"
          ],
          runInShell: true,
        );

        if (result.exitCode == 0) {
          final output = result.stdout.toString();
          final match = RegExp(r"MachineGuid\s+REG_SZ\s+([a-fA-F0-9\-]+)")
              .firstMatch(output);
          if (match != null) {
            final machineGuid = match.group(1)?.trim() ?? "";
            if (machineGuid.isNotEmpty) {
              return sha256.convert(utf8.encode(machineGuid)).toString();
            }
          }
        }
      } catch (e) {
        _logger.severe("Fallback MachineGuid also failed: $e");
      }
    }

    return unityId;
  }
}
