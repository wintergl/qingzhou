// Compile with x86_64-w64-mingw32-gcc -c. Checks the offsets and notification
// constants consumed by WindowsRuntimeMonitor; never executes a native API.
#include <winsock2.h>
#include <windows.h>
#include <netioapi.h>
#include <wlanapi.h>
#include <stddef.h>

_Static_assert(sizeof(void *) == 8, "This package targets Windows x64");
_Static_assert(offsetof(MIB_IPFORWARD_ROW2, InterfaceIndex) == 8, "Route interface offset");
_Static_assert(offsetof(MIB_IPFORWARD_ROW2, DestinationPrefix.PrefixLength) == 40, "Route prefix offset");
_Static_assert(sizeof(MIB_IPFORWARD_ROW2) == 104, "Route row size");
_Static_assert(offsetof(MIB_IPFORWARD_ROW2, NextHop.Ipv4.sin_addr) == 48, "Route next hop offset");
_Static_assert(offsetof(MIB_IPFORWARD_ROW2, Metric) == 84, "Route metric offset");
_Static_assert(offsetof(MIB_IPFORWARD_TABLE2, Table) == 8, "Route table offset");
_Static_assert(wlan_notification_acm_connection_complete == 10, "Wi-Fi connected code");
_Static_assert(wlan_notification_acm_disconnected == 21, "Wi-Fi disconnected code");
_Static_assert(WLAN_NOTIFICATION_SOURCE_ACM == 0x8, "Wi-Fi source");
_Static_assert(offsetof(WLAN_NOTIFICATION_DATA, pData) == 32, "WLAN data alignment");
_Static_assert(sizeof(WLAN_NOTIFICATION_DATA) == 40, "WLAN structure size");
_Static_assert(sizeof(SYSTEM_POWER_STATUS) == 12, "Power status layout");
_Static_assert(offsetof(SYSTEM_POWER_STATUS, SystemStatusFlag) == 3, "Battery saver offset");
_Static_assert(offsetof(POWERBROADCAST_SETTING, Data) == 20, "Power payload offset");
