# App Privacy for 1.0.29

The current public label says Data Not Collected. Update it for the optional notification relay and computer queue.

| Data type | Purpose | Linked to user/device | Tracking |
| --- | --- | --- | --- |
| Device ID | App Functionality | Yes | No |
| Product Interaction | App Functionality | Yes | No |
| Other User Content | App Functionality | Yes | No |
| Photos or Videos | App Functionality | Yes | No |

The subscription table retains the APNs token. Delivery records and encrypted queued content reference that subscription, so the data remains linked to a device. The pairing key passes through the relay; the content is not claimed to be inaccessible to the developer. No account, advertising, analytics, or tracking is added. This is a disclosure correction, with no change to data collection or app behavior.

The bundle's PrivacyInfo.xcprivacy is corrected to match. Local drafts alone remain on-device and do not constitute server collection. The deployed privacy and support pages already explain the optional relay and queue (verified September 21, 2026).

Apple guidance: https://developer.apple.com/app-store/app-privacy-details/ (Data linked to the user).
