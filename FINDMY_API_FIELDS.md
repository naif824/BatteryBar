# Find My API — Available Device Fields

Data returned per device from `/fmipservice/client/web/refreshClient` (and `initClient`).

## Identity

| Field | Type | Example | Description |
|---|---|---|---|
| `id` | String | `"AdckrjREcMxy..."` | Unique device identifier |
| `name` | String | `"Naif's MacBook Air"` | User-given device name |
| `deviceDisplayName` | String | `"MacBook Air (13-inch, M3, 2024)"` | Full model description |
| `modelDisplayName` | String | `"MacBook Air"` | Short model name |
| `deviceModel` | String | `"Mac15_12-midnight"` | Internal model + color |
| `rawDeviceModel` | String | `"Mac15,12"` | Raw hardware model |
| `deviceClass` | String | `"MacBookAir"` | Device class (iPhone, iPad, MacBookAir, Watch, etc.) |
| `deviceColor` | String | `"midnight"` | Device color variant |
| `baUUID` | String | `"D90F83A9-..."` | Bluetooth UUID |
| `prsId` | String? | `null` | Person ID (family sharing) |
| `encodedDeviceId` | String? | `null` | Encoded device ID |
| `commandLookupId` | String | `"1ySuNERw..."` | Command lookup reference |

## Battery & Power

| Field | Type | Example | Description |
|---|---|---|---|
| `batteryLevel` | Double | `1.0` | Battery level 0.0–1.0 (multiply by 100 for %) |
| `batteryStatus` | String | `"NotCharging"` | Charging state: `"Charging"`, `"NotCharging"`, `"Charged"`, `"Unknown"` |
| `lowPowerMode` | Bool | `false` | Low Power Mode active |
| `darkWake` | Bool | `false` | Mac is in dark wake (lid closed, background tasks) |

## Device Status

| Field | Type | Example | Description |
|---|---|---|---|
| `deviceStatus` | String | `"200"` | Online status. `"200"` = online/reachable |
| `deviceWithYou` | Bool | `false` | Is the device near you |
| `isMac` | Bool | `true` | Is a Mac |
| `isConsideredAccessory` | Bool | `false` | Is an accessory (AirPods, AirTag, etc.) |
| `fmlyShare` | Bool | `false` | Is a family-shared device |
| `thisDevice` | Bool | `false` | Is this the device making the query |
| `nwd` | Bool | `false` | Nearby wearable device |

## Location

| Field | Type | Example | Description |
|---|---|---|---|
| `location` | Object? | `{...}` | Location data (null if unavailable) |
| `location.latitude` | Double | `24.877543` | GPS latitude |
| `location.longitude` | Double | `46.597180` | GPS longitude |
| `location.altitude` | Double | `0` | Altitude in meters |
| `location.horizontalAccuracy` | Double | `35` | Horizontal accuracy in meters |
| `location.verticalAccuracy` | Double | `0` | Vertical accuracy in meters |
| `location.positionType` | String | `"Wifi"` | How location was determined: `"Wifi"`, `"GPS"`, `"Cell"` |
| `location.timeStamp` | Int64 | `1776246574252` | Location timestamp (epoch milliseconds) |
| `location.isOld` | Bool | `false` | Location data is stale |
| `location.isInaccurate` | Bool | `false` | Location is inaccurate |
| `location.floorLevel` | Int | `0` | Indoor floor level |
| `location.locationFinished` | Bool | `true` | Location lookup completed |
| `location.locationType` | String | `""` | Location type detail |
| `location.locationMode` | String? | `null` | Location mode |
| `locationEnabled` | Bool | `true` | Find My location enabled on device |
| `locationCapable` | Bool | `true` | Device supports location |
| `isLocating` | Bool | `true` | Currently locating |
| `locFoundEnabled` | Bool | `false` | Location found enabled |

## Security & Lost Mode

| Field | Type | Example | Description |
|---|---|---|---|
| `activationLocked` | Bool | `true` | Activation Lock enabled |
| `lostModeEnabled` | Bool | `false` | Lost Mode currently active |
| `lostModeCapable` | Bool | `false` | Device supports Lost Mode |
| `lostDevice` | Object? | `null` | Lost device details |
| `lostTimestamp` | String | `""` | When Lost Mode was activated |
| `lockedTimestamp` | String? | `null` | When device was locked |
| `passcodeLength` | Int | `6` | Device passcode length |
| `remoteLock` | Object? | `null` | Remote lock status |
| `remoteWipe` | Object? | `null` | Remote wipe status |
| `canWipeAfterLock` | Bool | | Can erase after locking |
| `wipeInProgress` | Bool | `false` | Wipe currently happening |
| `wipedTimestamp` | String? | `null` | When device was wiped |
| `pendingRemove` | Bool | `false` | Pending removal from account |
| `pendingRemoveUntilTS` | Int | `0` | Removal pending until timestamp |

## Features (capabilities)

| Field | Type | Description |
|---|---|---|
| `features.LOC` | Bool | Location capable |
| `features.LCK` | Bool | Remote lock capable |
| `features.LKM` | Bool | Lost key mode |
| `features.REM` | Bool | Remote wipe capable |
| `features.PSS` | Bool | Play sound capable |
| `features.LYU` | Bool | Lost your (item tracking) |

## Messaging & Sound

| Field | Type | Description |
|---|---|---|
| `msg` | String? | Message displayed on device |
| `mesg` | String? | Message (alternate field) |
| `maxMsgChar` | Int | Max message characters |
| `snd` | Object? | Sound playback status |
| `audioChannels` | Array | Available audio channels for play sound |

## Repair & Service

| Field | Type | Description |
|---|---|---|
| `repairStatus` | String? | Repair status |
| `repairReady` | Bool | Repair ready |
| `repairDeviceReason` | String | Reason for repair |
| `repairReadyExpireTS` | Int | Repair ready expiration |

## Other

| Field | Type | Description |
|---|---|---|
| `rm2State` | Int | Unknown internal state |
| `brassStatus` | String | Unknown (`"false"`) |
| `scd` | Bool | Security code set |
| `scdPh` | String | Security code phone |
| `trackingInfo` | Object? | Tracking information |

## What BatteryBar Currently Uses

| Field | Used For |
|---|---|
| `id` | Device identification, hidden device tracking |
| `name` | Display name in menu |
| `deviceDisplayName` | Device classification |
| `deviceClass` | Device classification |
| `deviceStatus` | Online/offline (green/red dot) |
| `batteryLevel` | Battery percentage |
| `batteryStatus` | Charging indicator |
| `lowPowerMode` | LP indicator |

## What Could Be Added

| Feature | Fields Needed |
|---|---|
| Device location on map | `location.*` |
| Play sound on device | `audioChannels`, `snd`, `features.PSS` |
| Lost Mode toggle | `lostModeEnabled`, `lostModeCapable` |
| Last seen time | `location.timeStamp`, `location.isOld` |
| Device model icon | `rawDeviceModel`, `deviceClass` |
| Family device grouping | `fmlyShare`, `prsId` |
| Location accuracy indicator | `location.horizontalAccuracy`, `location.positionType` |
| Remote lock/wipe | `remoteLock`, `remoteWipe`, `features.LCK`, `features.REM` |
| "With you" indicator | `deviceWithYou` |
| Activation Lock status | `activationLocked` |
