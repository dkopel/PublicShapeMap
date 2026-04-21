/** Visualforce controller + remoting endpoint for the Public Shape Map. */
public inherited sharing class PSM_MapController {
  public static final Integer DEFAULT_MIN_ZOOM = 8;
  public static final Decimal DEFAULT_SIMPLIFY_TOLERANCE = 0.0001;
  public static final Integer MAX_BATCH_SPEC_COUNT = 8;
  public static final Integer MAX_BATCH_ERROR_SAMPLES = 5;
  public static final Integer CPU_SOFT_LIMIT_MS = 9300;

  /** For unit tests only: bypass folder id. */
  @TestVisible
  private static String testOverrideFolderRootId;
  @TestVisible
  private static String testOverrideFolderName;

  private static String cachedFolderRootId;
  private static Integer cachedMinZoomLevel;

  public String googleApiKey { get; private set; }
  public Integer minZoom { get; private set; }

  public PSM_MapController() {
    minZoom = resolveMinZoomLevel();
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
          'minZoom' => resolveMinZoomLevel()
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

  @RemoteAction
  public static String getVisibleShapesForViewport(
    Decimal minLat,
    Decimal maxLat,
    Decimal minLng,
    Decimal maxLng,
    Integer zoomLevel
  ) {
    try {
      String folderRootId = resolveFolderRootId();
      Integer configuredMinZoom = resolveMinZoomLevel();
      Integer z = (zoomLevel == null) ? 0 : zoomLevel;
      if (z < configuredMinZoom) {
        return JSON.serialize(
          new Map<String, Object>{
            'success' => true,
            'belowMinZoom' => true,
            'shapeSpecs' => new List<Object>(),
            'shapeCount' => 0,
            'debug' => new Map<String, Object>{
              'mode' => 'viewport-bbox',
              'folderRootId' => folderRootId,
              'renderedFeatures' => 0,
              'minZoom' => configuredMinZoom
            }
          }
        );
      }

      List<Map<String, Object>> shapeSpecs = PSM_GeoShapeApiService.listFolderShapeLoadSpecsForViewport(
        folderRootId,
        minLat,
        maxLat,
        minLng,
        maxLng
      );
      Integer renderedFeatures = shapeSpecs.size();
      return JSON.serialize(
        new Map<String, Object>{
          'success' => true,
          'belowMinZoom' => false,
          'shapeSpecs' => shapeSpecs,
          'shapeCount' => renderedFeatures,
          'debug' => new Map<String, Object>{
            'mode' => 'viewport-bbox',
            'folderRootId' => folderRootId,
            'renderedFeatures' => renderedFeatures,
            'minZoom' => configuredMinZoom
          }
        }
      );
    } catch (Exception e) {
      return JSON.serialize(new Map<String, Object>{ 'success' => false, 'error' => e.getMessage() });
    }
  }

  @RemoteAction
  public static String getDissolvedShapeGeometry(String childIdsCsv) {
    try {
      if (String.isBlank(childIdsCsv)) {
        return JSON.serialize(new Map<String, Object>{ 'success' => false, 'error' => 'Missing child ids.' });
      }
      Integer childIdCount = estimateCsvTokenCount(childIdsCsv);
      Map<String, Object> body = new Map<String, Object>{
        'id' => childIdsCsv,
        'simplifyTolerance' => computeSimplifyTolerance(childIdCount),
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
      // Avoid expensive deserialize/serialize of very large GeoJSON in Apex.
      // Returning raw response keeps CPU use low; the browser parses it.
      return JSON.serialize(new Map<String, Object>{ 'success' => true, 'responseBody' => res.getBody() });
    } catch (Exception e) {
      return JSON.serialize(new Map<String, Object>{ 'success' => false, 'error' => e.getMessage() });
    }
  }

  @RemoteAction
  public static String getDissolvedShapeGeometryBatch(String specsJson) {
    try {
      if (String.isBlank(specsJson)) {
        return JSON.serialize(new Map<String, Object>{ 'success' => false, 'error' => 'Missing specs payload.' });
      }
      Object parsed = JSON.deserializeUntyped(specsJson);
      if (!(parsed instanceof List<Object>)) {
        return JSON.serialize(new Map<String, Object>{ 'success' => false, 'error' => 'Expected JSON array payload.' });
      }
      List<Object> rawSpecs = (List<Object>) parsed;
      List<Object> featuresOut = new List<Object>();
      List<Object> errors = new List<Object>();
      Integer requested = 0;
      Integer maxSpecs = Math.min(rawSpecs.size(), MAX_BATCH_SPEC_COUNT);

      for (Integer i = 0; i < maxSpecs; i++) {
        if (Limits.getCpuTime() >= CPU_SOFT_LIMIT_MS) {
          addBatchError(errors, null, 'Stopped early to avoid Apex CPU limit. Retry remaining shapes.');
          break;
        }
        if (!(rawSpecs[i] instanceof Map<String, Object>)) {
          continue;
        }
        Map<String, Object> spec = (Map<String, Object>) rawSpecs[i];
        requested++;
        List<String> childIds = parseChildIds(spec.get('childIds'));
        if (childIds.isEmpty()) {
          continue;
        }
        try {
          Map<String, Object> body = new Map<String, Object>{
            'id' => String.join(childIds, ','),
            'simplifyTolerance' => computeSimplifyTolerance(childIds.size()),
            'fields' => 'id,name,geometry,type,centroid',
            'featureCollection' => true,
            'dissolve' => true
          };
          HttpResponse res = PSM_GeoShapeApiService.postGetShapes(body);
          if (res.getStatusCode() != 200) {
            addBatchError(
              errors,
              spec,
              'getshapes failed: HTTP ' + res.getStatusCode() + ' body=' + truncate(res.getBody(), 200)
            );
            continue;
          }
          List<Map<String, Object>> features = PSM_GeoShapeApiService.extractFeatures(res.getBody());
          if (features.isEmpty()) {
            continue;
          }
          Map<String, Object> feature = features[0];
          addSpecPropertiesToFeature(feature, spec);
          featuresOut.add(feature);
        } catch (Exception itemEx) {
          addBatchError(errors, spec, itemEx.getMessage());
        }
      }

      return JSON.serialize(
        new Map<String, Object>{
          'success' => true,
          'requestedCount' => requested,
          'loadedCount' => featuresOut.size(),
          'errorCount' => errors.size(),
          'features' => featuresOut,
          'errors' => errors
        }
      );
    } catch (Exception e) {
      return JSON.serialize(new Map<String, Object>{ 'success' => false, 'error' => e.getMessage() });
    }
  }

  private static List<String> parseChildIds(Object childIdsRaw) {
    List<String> out = new List<String>();
    if (!(childIdsRaw instanceof List<Object>)) {
      return out;
    }
    for (Object idVal : (List<Object>) childIdsRaw) {
      if (idVal == null) {
        continue;
      }
      String idText = String.valueOf(idVal).trim();
      if (!String.isBlank(idText)) {
        out.add(idText);
      }
    }
    return out;
  }

  private static Decimal computeSimplifyTolerance(Integer childIdCount) {
    Integer n = childIdCount == null ? 0 : childIdCount;
    if (n >= 4000) {
      return 0.001;
    }
    if (n >= 2000) {
      return 0.0006;
    }
    if (n >= 1000) {
      return 0.0003;
    }
    return DEFAULT_SIMPLIFY_TOLERANCE;
  }

  private static Integer estimateCsvTokenCount(String csv) {
    if (String.isBlank(csv)) {
      return 0;
    }
    Integer count = 1;
    for (Integer i = 0; i < csv.length(); i++) {
      if (csv.substring(i, i + 1) == ',') {
        count++;
      }
    }
    return count;
  }

  private static void addSpecPropertiesToFeature(Map<String, Object> feature, Map<String, Object> spec) {
    if (feature == null) {
      return;
    }
    Map<String, Object> props = ensureProperties(feature);
    if (spec != null) {
      Object n = spec.get('name');
      if (n != null && !String.isBlank(String.valueOf(n))) {
        props.put('name', String.valueOf(n));
      }
      Object c = spec.get('color');
      if (c != null && !String.isBlank(String.valueOf(c))) {
        props.put('color', String.valueOf(c));
      }
      Object shapeRecordId = spec.get('shapeRecordId');
      if (shapeRecordId != null && !String.isBlank(String.valueOf(shapeRecordId))) {
        props.put('shapeRecordId', String.valueOf(shapeRecordId));
      }
    }
    addCentroidProperties(feature, props);
  }

  private static Map<String, Object> ensureProperties(Map<String, Object> feature) {
    Object rawProps = feature.get('properties');
    if (rawProps instanceof Map<String, Object>) {
      return (Map<String, Object>) rawProps;
    }
    Map<String, Object> props = new Map<String, Object>();
    feature.put('properties', props);
    return props;
  }

  private static void addCentroidProperties(Map<String, Object> feature, Map<String, Object> props) {
    if (feature == null || props == null) {
      return;
    }
    Object centroidRaw = feature.get('centroid');
    if (!(centroidRaw instanceof Map<String, Object>)) {
      return;
    }
    Map<String, Object> centroid = (Map<String, Object>) centroidRaw;
    Object coordsRaw = centroid.get('coordinates');
    if (!(coordsRaw instanceof List<Object>)) {
      return;
    }
    List<Object> coords = (List<Object>) coordsRaw;
    if (coords.size() < 2) {
      return;
    }
    Decimal lng = toDecimal(coords[0]);
    Decimal lat = toDecimal(coords[1]);
    if (lat != null && lng != null) {
      props.put('centroidLng', lng);
      props.put('centroidLat', lat);
    }
  }

  private static Decimal toDecimal(Object val) {
    if (val == null) {
      return null;
    }
    try {
      return Decimal.valueOf(String.valueOf(val));
    } catch (Exception ignore) {
      return null;
    }
  }

  private static void addBatchError(List<Object> errors, Map<String, Object> spec, String message) {
    if (errors == null || errors.size() >= MAX_BATCH_ERROR_SAMPLES) {
      return;
    }
    Map<String, Object> row = new Map<String, Object>();
    if (spec != null) {
      row.put('shapeRecordId', spec.get('shapeRecordId'));
      row.put('name', spec.get('name'));
    }
    row.put('error', String.isBlank(message) ? 'Unknown dissolve error.' : message);
    errors.add(row);
  }

  private static String truncate(String text, Integer maxLen) {
    if (String.isBlank(text) || maxLen == null || maxLen <= 0) {
      return text;
    }
    if (text.length() <= maxLen) {
      return text;
    }
    return text.substring(0, maxLen) + '...';
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

  private static Integer resolveMinZoomLevel() {
    if (!Test.isRunningTest() && cachedMinZoomLevel != null) {
      return cachedMinZoomLevel;
    }
    Integer out = DEFAULT_MIN_ZOOM;
    try {
      PSM_Map_Config__mdt cfg = getActiveConfig();
      if (cfg != null && cfg.Zoom_Level__c != null) {
        Integer parsed = Integer.valueOf(String.valueOf(cfg.Zoom_Level__c));
        if (parsed > 0) {
          out = parsed;
        }
      }
    } catch (Exception ignore) {
      out = DEFAULT_MIN_ZOOM;
    }
    if (!Test.isRunningTest()) {
      cachedMinZoomLevel = out;
    }
    return out;
  }

  private static PSM_Map_Config__mdt getActiveConfig() {
    List<PSM_Map_Config__mdt> rows = [
      SELECT DeveloperName, MasterLabel, Folder_Name__c, Folder_Id__c, Google_API_Key__c, Zoom_Level__c
      FROM PSM_Map_Config__mdt
      LIMIT 1
    ];
    if (rows.isEmpty()) {
      throw new AuraHandledException('No PSM_Map_Config__mdt records are defined.');
    }
    return rows[0];
  }
}
