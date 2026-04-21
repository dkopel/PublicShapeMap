/** Visualforce controller + remoting endpoint for the Public Shape Map. */
public inherited sharing class PSM_MapController {
  public static final Integer DEFAULT_MIN_ZOOM = 5;

  /** For unit tests only: bypass folder id. */
  @TestVisible
  private static String testOverrideFolderRootId;
  @TestVisible
  private static String testOverrideFolderName;

  private static String cachedFolderRootId;

  public String googleApiKey { get; private set; }
  public Integer minZoom { get; private set; }

  public PSM_MapController() {
    minZoom = DEFAULT_MIN_ZOOM;
    try {
      PSM_Map_Config__mdt cfg = getActiveConfig();
      googleApiKey = cfg.Google_API_Key__c;
    } catch (Exception e) {
      googleApiKey = '';
    }
  }

  @RemoteAction
  public static String getMapBootstrap() {
    try {
      PSM_Map_Config__mdt cfg = getActiveConfig();
      return JSON.serialize(
        new Map<String, Object>{
          'success' => true,
          'googleApiKey' => cfg.Google_API_Key__c,
          'minZoom' => DEFAULT_MIN_ZOOM
        }
      );
    } catch (Exception e) {
      return JSON.serialize(new Map<String, Object>{ 'success' => false, 'error' => e.getMessage() });
    }
  }

  /** Returns all folder child geometries in one load. */
  @RemoteAction
  public static String getAllShapesForFolder() {
    try {
      String folderRootId = resolveFolderRootId();
      List<Map<String, Object>> shapeSpecs = PSM_GeoShapeApiService.listFolderShapeLoadSpecs(folderRootId);
      Integer renderedFeatures = shapeSpecs.size();

      Map<String, Object> debug = new Map<String, Object>();
      debug.put('renderedFeatures', renderedFeatures);
      debug.put('folderRootId', folderRootId);
      debug.put('mode', 'client-geoshapes');

      return JSON.serialize(
        new Map<String, Object>{
          'success' => true,
          'belowMinZoom' => false,
          'shapeSpecs' => shapeSpecs,
          'shapeCount' => renderedFeatures,
          'debug' => debug
        }
      );
    } catch (Exception e) {
      return JSON.serialize(
        new Map<String, Object>{
          'success' => false,
          'error' => e.getMessage()
        }
      );
    }
  }

  /**
   * Backward-compatible wrapper. Viewport parameters are intentionally ignored;
   * this map now always loads all shapes for the configured folder.
   */
  @RemoteAction
  public static String getVisibleShapesForViewport(
    Decimal minLat,
    Decimal maxLat,
    Decimal minLng,
    Decimal maxLng,
    Integer zoomLevel
  ) {
    return getAllShapesForFolder();
  }

  @RemoteAction
  public static String getDissolvedShapeGeometry(String childIdsCsv) {
    try {
      if (String.isBlank(childIdsCsv)) {
        return JSON.serialize(new Map<String, Object>{ 'success' => false, 'error' => 'Missing child ids.' });
      }
      Map<String, Object> body = new Map<String, Object>{
        'id' => childIdsCsv,
        'simplifyTolerance' => 0.0001,
        'fields' => 'id,name,geometry,type,centroid',
        'featureCollection' => true,
        'dissolve' => true
      };
      HttpResponse res = PSM_GeoShapeApiService.postGetShapes(body);
      if (res.getStatusCode() != 200) {
        return JSON.serialize(
          new Map<String, Object>{
            'success' => false,
            'error' => 'getshapes failed: HTTP ' + res.getStatusCode(),
            'body' => res.getBody()
          }
        );
      }
      return JSON.serialize(new Map<String, Object>{ 'success' => true, 'responseBody' => res.getBody() });
    } catch (Exception e) {
      return JSON.serialize(new Map<String, Object>{ 'success' => false, 'error' => e.getMessage() });
    }
  }

  private static String resolveFolderRootId() {
    if (Test.isRunningTest() && !String.isBlank(testOverrideFolderRootId)) {
      return testOverrideFolderRootId;
    }
    if (!Test.isRunningTest() && !String.isBlank(cachedFolderRootId)) {
      return cachedFolderRootId;
    }

    PSM_Map_Config__mdt cfg = getActiveConfig();
    if (cfg == null) {
      throw new AuraHandledException('Missing map config metadata record.');
    }

    if (!String.isBlank(cfg.Folder_Id__c)) {
      String folderId = cfg.Folder_Id__c.trim();
      if (!Test.isRunningTest()) {
        cachedFolderRootId = folderId;
      }
      return folderId;
    }

    String folderName = (Test.isRunningTest() && !String.isBlank(testOverrideFolderName))
      ? testOverrideFolderName
      : cfg.Folder_Name__c;
    if (String.isBlank(folderName)) {
      throw new AuraHandledException('Map config requires Folder_Id__c or Folder_Name__c.');
    }

    String resolved = PSM_GeoShapeApiService.resolveFolderId(folderName.trim());
    if (!Test.isRunningTest()) {
      cachedFolderRootId = resolved;
    }
    return resolved;
  }

  private static PSM_Map_Config__mdt getActiveConfig() {
    List<PSM_Map_Config__mdt> rows = [
      SELECT DeveloperName, MasterLabel, Folder_Name__c, Folder_Id__c, Google_API_Key__c
      FROM PSM_Map_Config__mdt
      LIMIT 1
    ];
    if (rows.isEmpty()) {
      throw new AuraHandledException('No PSM_Map_Config__mdt records are defined.');
    }
    return rows[0];
  }
}
