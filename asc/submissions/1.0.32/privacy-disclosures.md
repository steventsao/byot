# App Privacy for 1.0.32

1.0.31's label declares the optional notification relay and computer queue (Device ID, Product Interaction, Other User Content, Photos or Videos: App Functionality, linked, no tracking). Keep those rows and **add** the opt-in usage data, which is **not linked** to the user:

| Data type | Purpose | Linked to user/device | Tracking |
| --- | --- | --- | --- |
| Product Interaction | Analytics | No | No |
| Other Diagnostic Data | Analytics | No | No |
| Device ID | Analytics | No | No |
| Coarse Location | Analytics | No | No |

Product Interaction and Device ID therefore appear twice: once under "Data Linked to You" (relay, App Functionality) and once under "Data Not Linked to You" (usage data, Analytics). Apple's form allows both for one data type.

Why these four: the seven events are product interactions; `error_class` is diagnostic; the random install id is a device-level identifier; PostHog derives a country from the request address. Nothing is collected until the person turns usage data on, and the install id is deleted when they turn it off. The bundle's `PrivacyInfo.xcprivacy` declares the same four, not linked, not tracking, purpose Analytics.

Apple guidance: https://developer.apple.com/app-store/app-privacy-details/
