# Public Shape Map (Salesforce)

Custom Site-ready map that shows Geopointe **shapes** from a configured **folder** using Salesforce-side remoting and batched dissolve requests.

## Configuration (Custom Metadata)

Type: **PSM Map Config** (`PSM_Map_Config__mdt`)

- **Folder Name** (`Folder_Name__c`) – exact Geopointe folder name (first match if duplicates exist in search results).
- **Folder Id** (`Folder_Id__c`) – required Salesforce/Geopointe folder id used as the only folder selector.
- **Google API Key** (`Google_API_Key__c`) – Maps JavaScript API key (restrict by HTTP referrer to your Site / Salesforce domain).

Seed record: `PSM_Map_Config.Default_Map` – update values after deploy.

## Pages

| Page | Purpose |
|------|---------|
| `PSM_SiteHost` | Host page with iframe to the map (use as Site “Active Site Home Page” or custom URL). |
| `PSM_MapFrame` | Google Map + remoting to load shape specs, then request dissolved polygons in Salesforce-side batches. |

## Salesforce Site setup (manual)

1. **Deploy** metadata (including Remote Site `Geopointe_API` → `https://api.geopointe.io`).
2. Edit **Custom Metadata** `Default_Map`: set `Folder_Id__c` and Google API key.
3. Create or open a **Site**; add **Visualforce** pages `PSM_SiteHost` and `PSM_MapFrame` to Site **Visualforce Page Access**.
4. **Guest User Profile** (or logged-in users): enable Apex class access for `PSM_MapController`, `PSM_MapFrameController`, and related classes; allow **HTTP Callouts** for the integration user if required by your org.
5. **Google Cloud**: allowlist your Site URL (and `*.force.com` / My Domain as needed) for the Maps API key.

## API behavior

- Calls `POST https://api.geopointe.io/v2/geoShapes/getshapes` with headers `x-application-name: geopointe`, `x-user-id`, `x-organization-id` (same pattern as Geopointe public map samples).
- Loads shape specs directly from configured `Folder_Id__c`, then requests dissolved geometries in bounded remoting batches.

For non-production Geopointe endpoints, add another Remote Site and adjust `PSM_GeoShapeApiService.GETSHAPES_ENDPOINT`.
