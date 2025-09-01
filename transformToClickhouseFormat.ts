import * as fs from 'fs';
import { createStringifyStream, createParseStream } from 'big-json';

const INPUT_FILE = 'a.json';
const OUTPUT_FILE = 'flattened_output.json';

interface EnhancedMergedLog {
  [key: string]: any;
}

function transformToClickhouseFormat(document: EnhancedMergedLog): any {
  return {
    timestamp: document['@timestamp'] || new Date().toISOString(),
    tag: document.tag || null,
    identifiedWith: document.identifiedWith || null,
    correlationId: document.correlationId || null,
    platform: document.platform || null,
    sdkIdentifier: document.sdkIdentifier || null,
    sdkPlatform: document.sdkPlatform || null,
    sdkVersion: document.sdkVersion || null,
    sdkState_beatExecutionState: document.sdkState?.beatExecutionState || null,
    sdkState_controlExecutionState: document.sdkState?.controlExecutionState || null,
    instanceId: document.instanceId || null,
    sessionId: document.sessionId || null,
    watcherMail: document.watcherMail || null,
    occurence: document.occurence || null,
    appInfo_alternativeCertHashes: document.appInfo?.alternativeCertHashes || null,
    appInfo_appIdentifier: document.appInfo?.appIdentifier || null,
    appInfo_appVersion: document.appInfo?.appVersion || null,
    appInfo_applicationIdentifier: document.appInfo?.applicationIdentifier || null,
    appInfo_certHash: document.appInfo?.certHash || null,
    appInfo_installationSource: document.appInfo?.installationSource || null,
    appInfo_installedFromUnofficialStore: document.appInfo?.installedFromUnofficialStore || null,
    deviceId_androidId: document.deviceId?.androidId || null,
    deviceId_fingerprintV3: document.deviceId?.fingerprintV3 || null,
    deviceId_mediaDrm: document.deviceId?.mediaDrm || null,
    deviceId_currentVendorId: document.deviceId?.currentVendorId || null,
    deviceId_oldVendorId: document.deviceId?.oldVendorId || null,
    defaultDeviceId: document.defaultDeviceId || null,
    deviceInfo_manufacturer: document.deviceInfo?.manufacturer || null,
    deviceInfo_model: document.deviceInfo?.model || null,
    deviceInfo_osVersion: document.deviceInfo?.osVersion || null,
    deviceState_biometrics: document.deviceState?.biometrics || null,
    deviceState_hasGoogleMobileServices: document.deviceState?.hasGoogleMobileServices || null,
    deviceState_hasHuaweiMobileServices: document.deviceState?.hasHuaweiMobileServices || null,
    deviceState_hwBackedKeychain: document.deviceState?.hwBackedKeychain || null,
    deviceState_isVerifyAppsEnabled: document.deviceState?.isVerifyAppsEnabled || null,
    deviceState_security: document.deviceState?.security || null,
    deviceState_securityPatch: document.deviceState?.securityPatch || null,
    deviceState_isAdbEnabled: document.deviceState?.isAdbEnabled || null,
    deviceState_selinuxProperties_bootSelinuxProperty: document.deviceState?.selinuxProperties?.bootSelinuxProperty || null,
    deviceState_selinuxProperties_buildSelinuxProperty: document.deviceState?.selinuxProperties?.buildSelinuxProperty || null,
    deviceState_selinuxProperties_selinuxEnabledReflect: document.deviceState?.selinuxProperties?.selinuxEnabledReflect || null,
    deviceState_selinuxProperties_selinuxEnforcedReflect: document.deviceState?.selinuxProperties?.selinuxEnforcedReflect || null,
    deviceState_selinuxProperties_selinuxEnforcementFileContent: document.deviceState?.selinuxProperties?.selinuxEnforcementFileContent || null,
    deviceState_selinuxProperties_selinuxMode: document.deviceState?.selinuxProperties?.selinuxMode || null,
    configVersion: document.configVersion || null,
    dynamicConfigVersion: document.dynamicConfigVersion || null,
    externalId: document.externalId || null,
    geolocation_asOrganization: document.geolocation?.asOrganization || null,
    geolocation_city: document.geolocation?.city || null,
    geolocation_continent: document.geolocation?.continent || null,
    geolocation_country: document.geolocation?.country || null,
    geolocation_ip: document.geolocation?.ip || null,
    geolocation_latitude: document.geolocation?.latitude || null,
    geolocation_longitude: document.geolocation?.longitude || null,
    geolocation_postalCode: document.geolocation?.postalCode || null,
    geolocation_region: document.geolocation?.region || null,
    geolocation_regionCode: document.geolocation?.regionCode || null,
    geolocation_timezone: document.geolocation?.timezone || null,
    loggingSslPinning: document.loggingSslPinning || null,
    accessibilityApps: document.accessibilityApps || null,
    checks_monitoring_status: document.checks?.monitoring?.status || null,
    checks_monitoring_timeMs: document.checks?.monitoring?.timeMs || null,
    checks_accessibility_status: document.checks?.accessibility?.status || null,
    checks_accessibility_timeMs: document.checks?.accessibility?.timeMs || null,
    checks_appIntegrity_status: document.checks?.appIntegrity?.status || null,
    checks_appIntegrity_timeMs: document.checks?.appIntegrity?.timeMs || null,
    checks_debug_status: document.checks?.debug?.status || null,
    checks_debug_timeMs: document.checks?.debug?.timeMs || null,
    checks_devMode_status: document.checks?.devMode?.status || null,
    checks_devMode_timeMs: document.checks?.devMode?.timeMs || null,
    checks_deviceBinding_status: document.checks?.deviceBinding?.status || null,
    checks_deviceBinding_timeMs: document.checks?.deviceBinding?.timeMs || null,
    checks_hooks_status: document.checks?.hooks?.status || null,
    checks_hooks_timeMs: document.checks?.hooks?.timeMs || null,
    checks_malware_status: document.checks?.malware?.status || null,
    checks_malware_timeMs: document.checks?.malware?.timeMs || null,
    checks_obfuscationIssues_status: document.checks?.obfuscationIssues?.status || null,
    checks_obfuscationIssues_timeMs: document.checks?.obfuscationIssues?.timeMs || null,
    checks_overlay_status: document.checks?.overlay?.status || null,
    checks_overlay_timeMs: document.checks?.overlay?.timeMs || null,
    checks_privilegedAccess_status: document.checks?.privilegedAccess?.status || null,
    checks_privilegedAccess_timeMs: document.checks?.privilegedAccess?.timeMs || null,
    checks_simulator_status: document.checks?.simulator?.status || null,
    checks_simulator_timeMs: document.checks?.simulator?.timeMs || null,
    checks_systemVPN_status: document.checks?.systemVPN?.status || null,
    checks_systemVPN_timeMs: document.checks?.systemVPN?.timeMs || null,
    checks_screenCapture_status: document.checks?.screenCapture?.status || null,
    checks_screenCapture_timeMs: document.checks?.screenCapture?.timeMs || null,
    checks_unofficialStore_status: document.checks?.unofficialStore?.status || null,
    checks_unofficialStore_timeMs: document.checks?.unofficialStore?.timeMs || null,
    checks_adbEnabled_status: document.checks?.adbEnabled?.status || null,
    checks_adbEnabled_timeMs: document.checks?.adbEnabled?.timeMs || null,
    checks_screenRecording_status: document.checks?.screenRecording?.status || null,
    checks_screenRecording_timeMs: document.checks?.screenRecording?.timeMs || null,
    checks_screenshot_status: document.checks?.screenshot?.status || null,
    checks_screenshot_timeMs: document.checks?.screenshot?.timeMs || null,
    incidentReport_type: document.incidentReport?.type || null,
    incidentReport_info_executionState: document.incidentReport?.info?.executionState || null,
    incidentReport_info_sdkIntegrityCompromised: document.incidentReport?.info?.sdkIntegrityCompromised || null,
    incidentReport_info_featureTestingIgnored: document.incidentReport?.info?.featureTestingIgnored || null,
    incidentReport_info_apiMethodNameNotObfuscated: document.incidentReport?.info?.apiMethodNameNotObfuscated || null,
    incidentReport_info_appIntegrityCheckError: document.incidentReport?.info?.appIntegrityCheckError || null,
    incidentReport_info_areApksAvailable: document.incidentReport?.info?.areApksAvailable || null,
    incidentReport_info_areBinariesPresent: document.incidentReport?.info?.areBinariesPresent || null,
    incidentReport_info_areFilesPresent: document.incidentReport?.info?.areFilesPresent || null,
    incidentReport_info_areFoldersWritable: document.incidentReport?.info?.areFoldersWritable || null,
    incidentReport_info_areFridaLibrariesDetected: document.incidentReport?.info?.areFridaLibrariesDetected || null,
    incidentReport_info_areTestKeysEnabled: document.incidentReport?.info?.areTestKeysEnabled || null,
    incidentReport_info_canExecuteCommand: document.incidentReport?.info?.canExecuteCommand || null,
    incidentReport_info_canExecuteCommandUsingWhich: document.incidentReport?.info?.canExecuteCommandUsingWhich || null,
    incidentReport_info_androidCertificateInfo: document.incidentReport?.info?.certificateInfo || null,
    incidentReport_info_checkEmulatorBrand: document.incidentReport?.info?.checkEmulatorBrand || null,
    incidentReport_info_checkEmulatorDevice: document.incidentReport?.info?.checkEmulatorDevice || null,
    incidentReport_info_checkEmulatorFingerprint: document.incidentReport?.info?.checkEmulatorFingerprint || null,
    incidentReport_info_checkEmulatorHardware: document.incidentReport?.info?.checkEmulatorHardware || null,
    incidentReport_info_checkEmulatorManufacturer: document.incidentReport?.info?.checkEmulatorManufacturer || null,
    incidentReport_info_checkEmulatorModel: document.incidentReport?.info?.checkEmulatorModel || null,
    incidentReport_info_checkEmulatorProduct: document.incidentReport?.info?.checkEmulatorProduct || null,
    incidentReport_info_checkEmulatorPropertyValues: document.incidentReport?.info?.checkEmulatorPropertyValues || null,
    incidentReport_info_checkEmulatorUser: document.incidentReport?.info?.checkEmulatorUser || null,
    incidentReport_info_checkFrameworks: document.incidentReport?.info?.checkFrameworks || null,
    incidentReport_info_checkLine1Number: document.incidentReport?.info?.checkLine1Number || null,
    incidentReport_info_checkNativeMethods: document.incidentReport?.info?.checkNativeMethods || null,
    incidentReport_info_checkPropertyDebuggable: document.incidentReport?.info?.checkPropertyDebuggable || null,
    incidentReport_info_checkPropertyWhichIsOnlyOnEmulator: document.incidentReport?.info?.checkPropertyWhichIsOnlyOnEmulator || null,
    incidentReport_info_checkSimSerial: document.incidentReport?.info?.checkSimSerial || null,
    incidentReport_info_checkStackTrace: document.incidentReport?.info?.checkStackTrace || null,
    incidentReport_info_checkSubsriberId: document.incidentReport?.info?.checkSubsriberId || null,
    incidentReport_info_checkVoiceMailNumber: document.incidentReport?.info?.checkVoiceMailNumber || null,
    incidentReport_info_componentHeartbeat: document.incidentReport?.info?.componentHeartbeat || null,
    incidentReport_info_detectSharedObjsAndJarsLoadedInMemory: document.incidentReport?.info?.detectSharedObjsAndJarsLoadedInMemory || null,
    incidentReport_info_didAndroidIdChange: document.incidentReport?.info?.didAndroidIdChange || null,
    incidentReport_info_didKeyStoreChange: document.incidentReport?.info?.didKeyStoreChange || null,
    incidentReport_info_fakeDeviceProfile: document.incidentReport?.info?.fakeDeviceProfile || null,
    incidentReport_info_fridaNative: document.incidentReport?.info?.fridaNative || null,
    incidentReport_info_hasInvalidSignatureDigest: document.incidentReport?.info?.hasInvalidSignatureDigest || null,
    incidentReport_info_hasInvalidSignatureDigestNative: document.incidentReport?.info?.hasInvalidSignatureDigestNative || null,
    incidentReport_info_hasMultipleSignatures: document.incidentReport?.info?.hasMultipleSignatures || null,
    incidentReport_info_hasTracerPid: document.incidentReport?.info?.hasTracerPid || null,
    incidentReport_info_incorrectPackageName: document.incidentReport?.info?.incorrectPackageName || null,
    incidentReport_info_incorrectPackageNameNative: document.incidentReport?.info?.incorrectPackageNameNative || null,
    incidentReport_info_isApplicationFlagEnabled: document.incidentReport?.info?.isApplicationFlagEnabled || null,
    incidentReport_info_isBuildConfigDebug: document.incidentReport?.info?.isBuildConfigDebug || null,
    incidentReport_info_isDebuggerConnected: document.incidentReport?.info?.isDebuggerConnected || null,
    incidentReport_info_isDeveloperModeEnabled: document.incidentReport?.info?.isDeveloperModeEnabled || null,
    incidentReport_info_isFridaProcessInProc: document.incidentReport?.info?.isFridaProcessInProc || null,
    incidentReport_info_isFridaServerListening: document.incidentReport?.info?.isFridaServerListening || null,
    incidentReport_info_isObscuredMotionEvent: document.incidentReport?.info?.isObscuredMotionEvent || null,
    incidentReport_info_isOtaCertificateMissing: document.incidentReport?.info?.isOtaCertificateMissing || null,
    incidentReport_info_isSElinuxInPermisiveMode: document.incidentReport?.info?.isSElinuxInPermisiveMode || null,
    incidentReport_info_isSafetyNetBypassDetected: document.incidentReport?.info?.isSafetyNetBypassDetected || null,
    incidentReport_info_isSystemPropertyEqualTo: document.incidentReport?.info?.isSystemPropertyEqualTo || null,
    incidentReport_info_isVpnRunning: document.incidentReport?.info?.isVpnRunning || null,
    incidentReport_info_isXposedVersionAvailable: document.incidentReport?.info?.isXposedVersionAvailable || null,
    incidentReport_info_malwarePackages: document.incidentReport?.info?.malwarePackages || null,
    incidentReport_info_overlayInstalledApps: document.incidentReport?.info?.overlayInstalledApps || null,
    incidentReport_info_rootNative: document.incidentReport?.info?.rootNative || null,
    incidentReport_info_unknownServices: document.incidentReport?.info?.unknownServices || null,
    incidentReport_info_unofficialInstallationSource: document.incidentReport?.info?.unofficialInstallationSource || null,
    incidentReport_info_unofficialInstallationSourceNative: document.incidentReport?.info?.unofficialInstallationSourceNative || null,
    incidentReport_info_hasFeatureTestingData: document.incidentReport?.info?.hasFeatureTestingData || null,
    incidentReport_info_appId: document.incidentReport?.info?.appId || null,
    incidentReport_info_VPNInterfaces: document.incidentReport?.info?.VPNInterfaces || null,
    incidentReport_info_appPaths: document.incidentReport?.info?.appPaths || null,
    incidentReport_info_bundleId: document.incidentReport?.info?.bundleId || null,
    incidentReport_info_bundleIdNative: document.incidentReport?.info?.bundleIdNative || null,
    incidentReport_info_iosCertificateInfo: document.incidentReport?.info?.certificateInfo || null,
    incidentReport_info_dylds: document.incidentReport?.info?.dylds || null,
    incidentReport_info_dylibs: document.incidentReport?.info?.dylibs || null,
    incidentReport_info_encryptedBinary: document.incidentReport?.info?.encryptedBinary || null,
    incidentReport_info_ffl: document.incidentReport?.info?.ffl || null,
    incidentReport_info_portOpen: document.incidentReport?.info?.portOpen || null,
    incidentReport_info_provisionIntegrity: document.incidentReport?.info?.provisionIntegrity || null,
    incidentReport_info_sBifValue: document.incidentReport?.info?.sBifValue || null,
    incidentReport_info_sbiR: document.incidentReport?.info?.sbiR || null,
    incidentReport_info_sbiW: document.incidentReport?.info?.sbiW || null,
    incidentReport_info_slPaths: document.incidentReport?.info?.slPaths || null,
    incidentReport_info_sysasm: document.incidentReport?.info?.sysasm || null,
    incidentReport_info_teamId: document.incidentReport?.info?.teamId || null,
    incidentReport_info_teamIdNative: document.incidentReport?.info?.teamIdNative || null,
    type: document.type || 'INFO',
    valid: document.valid !== undefined ? document.valid : true
  };
}

async function flattenFile() {
  try {
    const readStream = fs.createReadStream(INPUT_FILE);
    const parseStream = createParseStream();

    const outputStream = fs.createWriteStream(OUTPUT_FILE);
    outputStream.write('[');

    let first = true;
    let count = 0;

    parseStream.on('data', (data) => {
      if (Array.isArray(data)) {
        data.forEach((log: EnhancedMergedLog) => {
          const transformed = transformToClickhouseFormat(log);
          if (!first) {
            outputStream.write(',');
          }
          outputStream.write(JSON.stringify(transformed));
          first = false;
          count++;
        });
      } else {
        // If not an array, treat as single object
        const transformed = transformToClickhouseFormat(data);
        if (!first) {
          outputStream.write(',');
        }
        outputStream.write(JSON.stringify(transformed));
        first = false;
        count++;
      }
    });

    parseStream.on('end', () => {
      outputStream.write(']');
      outputStream.end();
      console.log(`Flattened data written to ${OUTPUT_FILE}. Processed ${count} records.`);
    });

    parseStream.on('error', (err) => {
      console.error('Parsing error:', err.message);
    });

    readStream.pipe(parseStream);
  } catch (error) {
    if (error instanceof Error) {
      console.error('Error:', error.message);
    } else {
      console.error('Unexpected error:', error);
    }
  }
}

flattenFile();
