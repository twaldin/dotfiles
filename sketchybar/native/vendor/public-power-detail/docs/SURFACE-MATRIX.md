# Prototype surface matrix

| Surface | Production binding | Closed result |
|---|---|---|
| Internal battery and UPS inventory | One `IOPSCopyPowerSourcesInfo` snapshot, list, and fixed-key descriptions | `absent`, `present`, `ambiguous`, `unavailable`, or `unsupported_type_present`; UPS data never fills battery fields |
| Charge and capacity | Strict IOPowerSources Boolean, integer, and source-string values | Exact charge enum; bounded percentage; explicit raw current/maximum availability |
| Source and aggregate time | Per-source fixed keys and `IOPSGetTimeRemainingEstimate` | Minutes, calculating, not applicable, unavailable; aggregate seconds, unknown, unlimited, unavailable |
| Low warning | `IOPSGetBatteryWarningLevel` | `none`, `early`, `final`, `unknown` |
| Health and condition | Fixed IOPowerSources health keys | SDK categories only; missing condition is `no_reported_condition` |
| Failures | Fixed internal-failure and failure-mode keys | Fixed categories, categorical unknown flag, count; no raw unknown text |
| Design and nominal capacity | Fixed capacity keys | Raw values and nominal/design only; no Apple Maximum Capacity claim |
| Cycle count | `IOPMCopyBatteryInfo` | Available only for one dictionary and one nonnegative strict integer |
| Electrical | Voltage, current, and temperature fixed keys | mV, signed mA, C; no battery wattage, current direction, wear, or danger inference |
| Adapter | `IOPSCopyExternalPowerAdapterDetails` | `attached` or `not_attached_or_unavailable`; watts/current only |
| Low Power | `ProcessInfo.isLowPowerModeEnabled` | `on` or `off_or_unsupported` |
| Load advisory | Combined public function and detailed public dictionary | Closed Great, OK, Bad, unavailable for combined and battery contribution |
| Active timers | Root power connection and three `IOPMGetAggressiveness` reads | Reported minutes with `current_active_value`; zero has no added meaning |
| Sleep capability | `IOPMSleepEnabled` | Supported, full sleep unavailable, unavailable |
| System transition | Workspace sleep/wake notifications | Last transient `will_sleep` or `did_wake`; no time |
| Display power | Two equal online-display snapshots around active/asleep reads | All awake, some asleep, all asleep, unavailable; no identifiers |
| Session transition | Workspace active/inactive notifications | Transition only; lock state always unavailable |
| Schedule | `IOPMCopyScheduledPowerEvents` | Count only; no item is read |
| Settings | Fixed bundle resolution and `openApplication` source design | One sealed main-application action; `pane_claim` is `none` |

All reader calls use `PublicPowerBindings`. Notifications invalidate values and coalesce one complete new sample. They do not carry sampled data. Source-notification creation failure is an explicit polling-only degraded mode; the heartbeat and other independent observers remain installed.
