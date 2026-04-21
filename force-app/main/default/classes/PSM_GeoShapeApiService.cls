/**
 * Geopointe geoShapes HTTP integration (same endpoint patterns as Geopointe / geoShapes getshapes).
 * Uses session-derived x-user-id and x-organization-id headers.
 */
public inherited sharing class PSM_GeoShapeApiService {
  public static final String GETSHAPES_ENDPOINT = 'https://api.geopointe.io/v2/geoShapes/getshapes';
  public static final Integer GEOMETRY_CHUNK_SIZE = 20;
  public static final Integer MAX_FOLDER_FALLBACK_CHILD_IDS = 40;
  public static final Integer MAX_ZIP_CENTROID_CALLOUTS = 40;
  private static List<String> coordinateFieldApiNamesCache;
  private static String geopointeShapeIdFieldApiNameCache;
  @TestVisible
  private static String testOverrideHeaderUserId;
  @TestVisible
  private static String testOverrideHeaderOrgId;
  private static final List<String> FIXED_LAT_LNG_FIELDS = new List<String>{
    'geopointe__Lat_Lng_1__c',
    'geopointe__Lat_Lng_2__c',
    'geopointe__Lat_Lng_3__c',
    'geopointe__Lat_Lng_4__c',
    'geopointe__Lat_Lng_5__c',
    'geopointe__Lat_Lng_6__c',
    'geopointe__Lat_Lng_7__c',
    'geopointe__Lat_Lng_8__c',
    'geopointe__Lat_Lng_9__c',
    'geopointe__Lat_Lng_10__c'
  };

  public class ShapeSummary {
    public String id;
    public Decimal lat;
    public Decimal lng;
    /** Immediate parent Geopointe id (folder or shape). */
    public String parentId;
    public String type;
    public Integer numberOfChildShapes;
    public ShapeSummary() {
    }
    public ShapeSummary(String shapeId, Decimal latitude, Decimal longitude) {
      this.id = shapeId;
      this.lat = latitude;
      this.lng = longitude;
    }
    public ShapeSummary(String shapeId, Decimal latitude, Decimal longitude, String parentGeopointeId, String shapeType) {
      this.id = shapeId;
      this.lat = latitude;
      this.lng = longitude;
      this.parentId = parentGeopointeId;
      this.type = shapeType;
    }
  }

  public static HttpResponse postGetShapes(Map<String, Object> body) {
    HttpRequest req = new HttpRequest();
    req.setEndpoint(GETSHAPES_ENDPOINT);
    req.setMethod('POST');
    req.setTimeout(120000);
    req.setHeader('Content-Type', 'application/json');
    req.setHeader('x-application-name', 'geopointe');
    req.setHeader('x-user-id', resolveHeaderUserId());
    req.setHeader('x-organization-id', resolveHeaderOrgId());
    req.setBody(JSON.serialize(body));
    return new Http().send(req);
  }

  private static String resolveHeaderUserId() {
    if (Test.isRunningTest() && !String.isBlank(testOverrideHeaderUserId)) {
      return testOverrideHeaderUserId;
    }
    String configured = Label.PSM_Geopointe_User_Id;
    if (!String.isBlank(configured) && normalize(configured) != 'use_userinfo') {
      return configured.trim();
    }
    return UserInfo.getUserId();
  }

  private static String resolveHeaderOrgId() {
    if (Test.isRunningTest() && !String.isBlank(testOverrideHeaderOrgId)) {
      return testOverrideHeaderOrgId;
    }
    String configured = Label.PSM_Geopointe_Org_Id;
    if (!String.isBlank(configured) && normalize(configured) != 'use_userinfo') {
      return configured.trim();
    }
    return UserInfo.getOrganizationId();
  }

  public static String getClientHeaderUserId() {
    return resolveHeaderUserId();
  }

  public static String getClientHeaderOrgId() {
    return resolveHeaderOrgId();
  }

  /**
   * Resolves folder Geopointe id by search + exact name match (first match).
   */
  public static String resolveFolderId(String folderName) {
    if (String.isBlank(folderName)) {
      throw new PSM_GeoShapeApiException('Folder name is required.');
    }
    String requested = normalize(folderName.trim());
    List<String> sampleNames = new List<String>();

    // First pass: direct search.
    Map<String, Object> body = baseFolderQueryBody();
    body.put('search', folderName.trim());
    List<Map<String, Object>> features = runGetShapesQuery(body, 'search');
    String bestId = null;
    Integer bestScore = -1;
    for (Map<String, Object> feature : features) {
      FolderCandidate c = scoreFolderCandidate(feature, requested);
      if (c != null) {
        if (!String.isBlank(c.sampleLabel)) {
          sampleNames.add(c.sampleLabel);
        }
        if (c.score > bestScore) {
          bestScore = c.score;
          bestId = c.id;
        }
      }
    }
    if (bestScore >= 0 && !String.isBlank(bestId)) {
      return bestId;
    }

    // Fallback: some guest contexts return empty search results even when folders exist.
    FolderDiscoveryResult discovered = discoverFolderIdByTraversal(requested);
    if (!String.isBlank(discovered.id)) {
      return discovered.id;
    }
    sampleNames.addAll(discovered.sampleNames);
    String diag = discovered.diagnostics.isEmpty() ? '' : ' Discovery probe notes: ' + String.join(discovered.diagnostics, ' | ');
    if (!sampleNames.isEmpty()) {
      Integer maxSample = Math.min(sampleNames.size(), 5);
      List<String> picked = new List<String>();
      for (Integer i = 0; i < maxSample; i++) {
        picked.add(sampleNames[i]);
      }
      throw new PSM_GeoShapeApiException(
        'No folder match for "' + folderName + '". Search/traversal sample: ' + String.join(picked, ', ') + diag
      );
    }
    throw new PSM_GeoShapeApiException(
      'No folder found from getshapes search/traversal: ' +
      folderName +
      '. Provide Folder_Id__c in metadata to bypass name lookup.' +
      diag
    );
  }

  private static Map<String, Object> baseFolderQueryBody() {
    return new Map<String, Object>{
      'onlyVisible' => false,
      'fields' => 'id,name,type,parentId,parentName,parentType,numberOfChildShapes',
      'featureCollection' => true
    };
  }

  private static List<Map<String, Object>> runGetShapesQuery(Map<String, Object> body, String mode) {
    HttpResponse res = postGetShapes(body);
    if (res.getStatusCode() != 200) {
      throw new PSM_GeoShapeApiException(
        'getshapes ' + mode + ' failed: HTTP ' + res.getStatusCode() + ' ' + res.getStatus() + ' body=' + truncate(res.getBody(), 500)
      );
    }
    return extractFeatures(res.getBody());
  }

  private class FolderDiscoveryResult {
    public String id;
    public Integer bestScore = -1;
    public List<String> sampleNames = new List<String>();
    public List<String> diagnostics = new List<String>();
  }

  private class FolderCandidate {
    public String id;
    public Integer score;
    public String sampleLabel;
  }

  private static FolderCandidate scoreFolderCandidate(Map<String, Object> feature, String requestedNorm) {
    String id = getFeatureId(feature);
    String name = getFeatureName(feature);
    String type = getFeatureType(feature);
    if (String.isBlank(type) || !isFolderType(type)) {
      return null;
    }
    FolderCandidate c = new FolderCandidate();
    c.id = id;
    c.score = String.isBlank(id) ? -1 : scoreCandidate(requestedNorm, normalize(name), id, type);
    c.sampleLabel = String.isBlank(name) ? null : name + ' [' + type + ']';
    return c;
  }

  private static FolderDiscoveryResult discoverFolderIdByTraversal(String requestedNorm) {
    FolderDiscoveryResult out = new FolderDiscoveryResult();
    Integer maxFolderVisits = 40;
    Set<String> visitedFolders = new Set<String>();
    List<String> queue = new List<String>();

    // Seed discovery with explicit parent root probes only (broad "seed" calls can 500).
    Map<String, Object> seedBodyB = baseFolderQueryBody();
    seedBodyB.put('parentId', null);
    List<Map<String, Object>> seedB = tryRunGetShapesQuery(seedBodyB, 'seed-parent-null', out.diagnostics);
    upsertBestFolderCandidate(seedB, requestedNorm, out);
    enqueueChildFolderIds(seedB, queue, visitedFolders);

    Map<String, Object> seedBodyC = baseFolderQueryBody();
    seedBodyC.put('parentId', '');
    List<Map<String, Object>> seedC = tryRunGetShapesQuery(seedBodyC, 'seed-parent-empty', out.diagnostics);
    upsertBestFolderCandidate(seedC, requestedNorm, out);
    enqueueChildFolderIds(seedC, queue, visitedFolders);

    while (!queue.isEmpty() && visitedFolders.size() < maxFolderVisits && String.isBlank(out.id)) {
      String folderId = queue.remove(0);
      if (String.isBlank(folderId) || visitedFolders.contains(folderId)) {
        continue;
      }
      visitedFolders.add(folderId);
      Map<String, Object> body = baseFolderQueryBody();
      body.put('parentId', folderId);
      List<Map<String, Object>> children = tryRunGetShapesQuery(body, 'parent-traversal', out.diagnostics);
      upsertBestFolderCandidate(children, requestedNorm, out);
      if (!String.isBlank(out.id)) {
        break;
      }
      enqueueChildFolderIds(children, queue, visitedFolders);
    }
    return out;
  }

  private static void upsertBestFolderCandidate(
    List<Map<String, Object>> features,
    String requestedNorm,
    FolderDiscoveryResult out
  ) {
    for (Map<String, Object> feature : features) {
      FolderCandidate c = scoreFolderCandidate(feature, requestedNorm);
      if (c == null) {
        continue;
      }
      if (!String.isBlank(c.sampleLabel) && out.sampleNames.size() < 10) {
        out.sampleNames.add(c.sampleLabel);
      }
      if (c.score > out.bestScore && !String.isBlank(c.id)) {
        out.bestScore = c.score;
        out.id = c.id;
      }
    }
  }

  private static void enqueueChildFolderIds(List<Map<String, Object>> features, List<String> queue, Set<String> visited) {
    for (Map<String, Object> feature : features) {
      String type = getFeatureType(feature);
      String id = getFeatureId(feature);
      if (isFolderType(type) && !String.isBlank(id) && !visited.contains(id)) {
        queue.add(id);
      }
    }
  }

  private static List<Map<String, Object>> tryRunGetShapesQuery(
    Map<String, Object> body,
    String mode,
    List<String> diagnostics
  ) {
    try {
      return runGetShapesQuery(body, mode);
    } catch (Exception e) {
      if (diagnostics != null && diagnostics.size() < 5) {
        diagnostics.add(mode + ': ' + truncate(e.getMessage(), 180));
      }
      return new List<Map<String, Object>>();
    }
  }

  /**
   * Lists descendant shapes under a folder root (centroid / bbox for viewport filtering + rollup).
   * Uses topParentId only when the root id is a Geopointe numeric id (API rejects Salesforce catalog ids here).
   * Otherwise walks the folder tree with repeated parentId calls so nested folders still yield shapes.
   */
  public static List<ShapeSummary> listShapeSummariesForParent(String parentFolderId) {
    List<ShapeSummary> salesforceRows = listShapeSummariesFromSalesforce(parentFolderId);
    if (!salesforceRows.isEmpty()) {
      return salesforceRows;
    }

    List<String> missingCenterIds = new List<String>();
    List<ShapeSummary> out = new List<ShapeSummary>();
    Boolean haveTopResult = false;

    Long topNumeric = tryParseGeopointeNumericTopParentId(parentFolderId);
    if (topNumeric != null) {
      Map<String, Object> deepBody = new Map<String, Object>{
        'topParentId' => topNumeric,
        'onlyVisible' => false,
        'fields' => 'id,name,type,parentId,centroid,numberOfChildShapes',
        'featureCollection' => true
      };
      HttpResponse deepRes = postGetShapes(deepBody);
      if (deepRes.getStatusCode() == 200) {
        List<Map<String, Object>> deepFeatures = extractFeatures(deepRes.getBody());
        if (!deepFeatures.isEmpty()) {
          missingCenterIds.clear();
          out = convertFeaturesToSummaries(deepFeatures, missingCenterIds);
          // Keep result when we have summaries or centroid backfill ids — do not replace with folder walk.
          haveTopResult = !out.isEmpty() || !missingCenterIds.isEmpty();
        }
      }
    }

    if (!haveTopResult) {
      missingCenterIds.clear();
      out = listShapeSummariesByFolderExpansion(parentFolderId, missingCenterIds);
    }

    // Some API responses omit centroid in metadata mode; derive center from full geometry response.
    if (!missingCenterIds.isEmpty()) {
      Map<String, Object> full = buildFeatureCollectionForIds(missingCenterIds);
      Object ff = full.get('features');
      if (ff instanceof List<Object>) {
        Set<String> haveIds = new Set<String>();
        for (ShapeSummary s : out) {
          haveIds.add(s.id);
        }
        for (Object row : (List<Object>) ff) {
          if (!(row instanceof Map<String, Object>)) {
            continue;
          }
          Map<String, Object> feature = (Map<String, Object>) row;
          String sid = getFeatureId(feature);
          if (String.isBlank(sid) || haveIds.contains(sid)) {
            continue;
          }
          LatLngPair c = extractCentroid(feature);
          if (c == null) {
            c = extractBBoxCenter(feature);
          }
          if (c != null) {
            ShapeSummary filled = new ShapeSummary(sid, c.lat, c.lng);
            filled.parentId = getFeatureParentId(feature);
            filled.type = getFeatureType(feature);
            out.add(filled);
            haveIds.add(sid);
          }
        }
      }
    }
    return out;
  }

  /**
   * Preferred path: query geopointe__Shape__c directly by geopointe__Folder__c hierarchy.
   * This avoids external API visibility mismatches and uses Salesforce data relationships.
   */
  private static List<ShapeSummary> listShapeSummariesFromSalesforce(String rootFolderId) {
    if (String.isBlank(rootFolderId)) {
      return new List<ShapeSummary>();
    }
    try {
      List<ShapeSummary> out = new List<ShapeSummary>();
      Map<String, ShapeSummary> missingCenterById = new Map<String, ShapeSummary>();
      List<String> missingCenterIds = new List<String>();
      Map<String, LatLngPair> zipCentroidCache = new Map<String, LatLngPair>();
      Set<String> seenShapeIds = new Set<String>();
      Set<String> visitedFolderIds = new Set<String>();
      List<String> queue = new List<String>{ rootFolderId };
      Integer maxFolderVisits = 200;
      Integer maxRows = 5000;

      while (!queue.isEmpty() && visitedFolderIds.size() < maxFolderVisits && out.size() < maxRows) {
        List<String> batchFolderIds = new List<String>();
        while (!queue.isEmpty() && batchFolderIds.size() < 100) {
          String f = queue.remove(0);
          if (String.isBlank(f) || visitedFolderIds.contains(f)) {
            continue;
          }
          visitedFolderIds.add(f);
          batchFolderIds.add(f);
        }
        if (batchFolderIds.isEmpty()) {
          continue;
        }

        for (SObject row : (new ShapeSoqlGateway()).queryByFolderIds(batchFolderIds)) {
          String sid = String.valueOf(row.get('Id'));
          if (String.isBlank(sid) || seenShapeIds.contains(sid)) {
            continue;
          }
          String type = (String) row.get('geopointe__Type__c');
          String parentId = (String) row.get('geopointe__Folder__c');
          if (isFolderType(type)) {
            if (!String.isBlank(sid) && !visitedFolderIds.contains(sid)) {
              queue.add(sid);
            }
            continue;
          }

          Decimal lat = toDecimal(row.get('geopointe__Center__Latitude__s'));
          Decimal lng = toDecimal(row.get('geopointe__Center__Longitude__s'));
          if (lat == null || lng == null) {
            Decimal latMin = toDecimal(row.get('geopointe__Lat_Min__c'));
            Decimal latMax = toDecimal(row.get('geopointe__Lat_Max__c'));
            Decimal lngMin = toDecimal(row.get('geopointe__Lng_Min__c'));
            Decimal lngMax = toDecimal(row.get('geopointe__Lng_Max__c'));
            if (latMin != null && latMax != null && lngMin != null && lngMax != null) {
              lat = (latMin + latMax) / 2;
              lng = (lngMin + lngMax) / 2;
            }
          }
          if (lat == null || lng == null) {
            List<String> zipCodes = extractZipCodesFromCoordinateFields(row);
            if (!zipCodes.isEmpty()) {
              Integer addedFromZips = 0;
              for (String zipCode : zipCodes) {
                LatLngPair zipCenter = resolveZipCentroid(zipCode, zipCentroidCache);
                if (zipCenter == null) {
                  continue;
                }
                out.add(new ShapeSummary(sid, zipCenter.lat, zipCenter.lng, parentId, type));
                addedFromZips++;
                if (out.size() >= maxRows) {
                  break;
                }
              }
              if (addedFromZips > 0) {
                seenShapeIds.add(sid);
                continue;
              }
            }

            ShapeSummary pending = new ShapeSummary(sid, null, null, parentId, type);
            missingCenterById.put(sid, pending);
            missingCenterIds.add(sid);
            seenShapeIds.add(sid);
            if ((out.size() + missingCenterIds.size()) >= maxRows) {
              break;
            }
            continue;
          }

          out.add(new ShapeSummary(sid, lat, lng, parentId, type));
          seenShapeIds.add(sid);
          if ((out.size() + missingCenterIds.size()) >= maxRows) {
            break;
          }
        }
      }

      if (!missingCenterIds.isEmpty()) {
        Map<String, Object> full = buildFeatureCollectionForIds(missingCenterIds);
        Object ff = full.get('features');
        if (ff instanceof List<Object>) {
          for (Object row : (List<Object>) ff) {
            if (!(row instanceof Map<String, Object>)) {
              continue;
            }
            Map<String, Object> feature = (Map<String, Object>) row;
            String sid = getFeatureId(feature);
            if (String.isBlank(sid)) {
              continue;
            }
            ShapeSummary pending = missingCenterById.get(sid);
            if (pending == null) {
              continue;
            }
            LatLngPair c = extractCentroid(feature);
            if (c == null) {
              c = extractBBoxCenter(feature);
            }
            if (c == null) {
              continue;
            }
            pending.lat = c.lat;
            pending.lng = c.lng;
            out.add(pending);
            if (out.size() >= maxRows) {
              break;
            }
          }
        }
      }
      return out;
    } catch (Exception ignore) {
      // Fall through to API strategy when package objects are unavailable/inaccessible.
      return new List<ShapeSummary>();
    }
  }

  private without sharing class ShapeSoqlGateway {
    public List<SObject> queryByFolderIds(List<String> folderIds) {
      if (folderIds == null || folderIds.isEmpty()) {
        return new List<SObject>();
      }
      String soql =
        'SELECT Id, Name, geopointe__Color__c, geopointe__Folder__c, geopointe__Type__c, ' +
        'geopointe__Center__Latitude__s, geopointe__Center__Longitude__s, ' +
        'geopointe__Lat_Min__c, geopointe__Lat_Max__c, geopointe__Lng_Min__c, geopointe__Lng_Max__c';
      String geopointeIdField = getGeopointeShapeIdFieldApiName();
      if (!String.isBlank(geopointeIdField)) {
        soql += ', ' + geopointeIdField;
      }
      for (String coordinateField : getCoordinateFieldApiNames()) {
        soql += ', ' + coordinateField;
      }
      soql += ' FROM geopointe__Shape__c WHERE geopointe__Folder__c IN :folderIds';
      return Database.query(soql);
    }
  }

  public static List<Map<String, Object>> listFolderShapeLoadSpecs(String folderId) {
    List<Map<String, Object>> out = new List<Map<String, Object>>();
    if (String.isBlank(folderId)) {
      return out;
    }
    Integer maxRows = 5000;
    for (SObject row : (new ShapeSoqlGateway()).queryByFolderIds(new List<String>{ folderId })) {
      String type = (String) row.get('geopointe__Type__c');
      if (isFolderType(type)) {
        continue;
      }
      List<String> childIds = extractChildShapeIdsFromCoordinateFields(row);
      if (childIds.isEmpty()) {
        continue;
      }
      Map<String, Object> spec = new Map<String, Object>();
      spec.put('shapeRecordId', row.get('Id'));
      spec.put('name', row.get('Name'));
      String color = normalizeHexColor(row.get('geopointe__Color__c'));
      if (!String.isBlank(color)) {
        spec.put('color', color);
      }
      spec.put('childIds', childIds);
      out.add(spec);
      if (--maxRows <= 0) {
        break;
      }
    }
    return out;
  }

  private static List<String> getCoordinateFieldApiNames() {
    if (coordinateFieldApiNamesCache != null) {
      return coordinateFieldApiNamesCache;
    }
    coordinateFieldApiNamesCache = new List<String>();
    try {
      Map<String, SObjectType> gd = Schema.getGlobalDescribe();
      if (!gd.containsKey('geopointe__Shape__c')) {
        return coordinateFieldApiNamesCache;
      }
      Map<String, Schema.SObjectField> fields = gd.get('geopointe__Shape__c').getDescribe().fields.getMap();
      for (String apiName : FIXED_LAT_LNG_FIELDS) {
        if (fields.containsKey(apiName)) {
          coordinateFieldApiNamesCache.add(apiName);
        }
      }
    } catch (Exception ignore) {
      // Best effort only; centroid fallback by shape id still runs.
    }
    return coordinateFieldApiNamesCache;
  }

  private static String getGeopointeShapeIdFieldApiName() {
    if (geopointeShapeIdFieldApiNameCache != null) {
      return geopointeShapeIdFieldApiNameCache;
    }
    // Intentionally disabled for performance and correctness in this org.
    geopointeShapeIdFieldApiNameCache = '';
    return geopointeShapeIdFieldApiNameCache;
  }

  private static List<String> extractZipCodesFromCoordinateFields(SObject row) {
    List<String> out = new List<String>();
    if (row == null) {
      return out;
    }
    Set<String> seen = new Set<String>();
    Pattern zipPattern = Pattern.compile('\\b\\d{5}(?:-\\d{4})?\\b');
    Integer consecutiveBlanks = 0;
    for (String fieldApiName : getCoordinateFieldApiNames()) {
      Object raw = row.get(fieldApiName);
      if (raw == null) {
        consecutiveBlanks++;
        if (consecutiveBlanks >= 1 && looksLikeLatLngBucket(fieldApiName)) {
          break;
        }
        continue;
      }
      String text = String.valueOf(raw);
      if (String.isBlank(text)) {
        consecutiveBlanks++;
        if (consecutiveBlanks >= 1 && looksLikeLatLngBucket(fieldApiName)) {
          break;
        }
        continue;
      }
      consecutiveBlanks = 0;
      String normalizedText = text.replaceAll('<[^>]+>', ',');
      Matcher m = zipPattern.matcher(normalizedText);
      while (m.find()) {
        String zip = m.group(0);
        if (!String.isBlank(zip) && !seen.contains(zip)) {
          seen.add(zip);
          out.add(zip);
          if (out.size() >= 100) {
            return out;
          }
        }
      }
    }
    return out;
  }

  private static Boolean looksLikeLatLngBucket(String fieldApiName) {
    String n = normalize(fieldApiName);
    return !String.isBlank(n) && (n.contains('lat_lng_') || n.contains('latlng'));
  }

  private class CoordinateFieldComparator implements Comparator<String> {
    public Integer compare(String a, String b) {
      Integer ai = extractTrailingInteger(a);
      Integer bi = extractTrailingInteger(b);
      if (ai != null && bi != null && ai != bi) {
        return ai < bi ? -1 : 1;
      }
      String an = normalize(a);
      String bn = normalize(b);
      if (an == bn) {
        return 0;
      }
      return an < bn ? -1 : 1;
    }
  }

  private static Integer extractTrailingInteger(String value) {
    if (String.isBlank(value)) {
      return null;
    }
    Matcher m = Pattern.compile('(\\d+)(?:__c)?$').matcher(value);
    if (!m.find()) {
      return null;
    }
    try {
      return Integer.valueOf(m.group(1));
    } catch (Exception ignore) {
      return null;
    }
  }

  private static LatLngPair resolveZipCentroid(String zipCode, Map<String, LatLngPair> cache) {
    if (String.isBlank(zipCode)) {
      return null;
    }
    String key = zipCode.trim();
    if (cache != null && cache.containsKey(key)) {
      return cache.get(key);
    }
    if (cache != null && cache.size() >= MAX_ZIP_CENTROID_CALLOUTS) {
      return null;
    }

    Map<String, Object> body = new Map<String, Object>{
      'search' => key,
      'type' => 'ZIP Code (USPS)',
      'fields' => 'id,type,centroid',
      'featureCollection' => true
    };
    List<Map<String, Object>> features = tryRunGetShapesQuery(body, 'zip-centroid:' + key, null);
    LatLngPair out = null;
    if (!features.isEmpty()) {
      out = extractCentroid(features[0]);
      if (out == null) {
        out = extractBBoxCenter(features[0]);
      }
    }
    if (cache != null) {
      cache.put(key, out);
    }
    return out;
  }

  /**
   * Geopointe topParentId must be a number. Salesforce geoShape folder ids (15/18 char) are not valid — return null.
   */
  private static Long tryParseGeopointeNumericTopParentId(String parentFolderId) {
    if (String.isBlank(parentFolderId)) {
      return null;
    }
    if (looksLikeSalesforceCatalogId(parentFolderId.trim())) {
      return null;
    }
    try {
      return Long.valueOf(parentFolderId.trim());
    } catch (Exception ignore) {
      return null;
    }
  }

  private static Boolean looksLikeSalesforceCatalogId(String value) {
    if (String.isBlank(value)) {
      return false;
    }
    Integer n = value.length();
    if (n != 15 && n != 18) {
      return false;
    }
    String first = value.substring(0, 1);
    if (!Pattern.compile('[a-zA-Z]').matcher(first).matches()) {
      return false;
    }
    Pattern p15 = Pattern.compile('[a-zA-Z0-9]{15}');
    Pattern p18 = Pattern.compile('[a-zA-Z0-9]{18}');
    return (n == 15 && p15.matcher(value).matches()) || (n == 18 && p18.matcher(value).matches());
  }

  /**
   * Breadth-first expansion: list children per folder until non-folder shapes are collected (nested catalogs).
   */
  private static List<ShapeSummary> listShapeSummariesByFolderExpansion(String rootFolderId, List<String> missingCenterIds) {
    List<Map<String, Object>> accumulated = new List<Map<String, Object>>();
    Set<String> seenShapeIds = new Set<String>();
    List<String> folderQueue = new List<String>();
    folderQueue.add(rootFolderId);
    Set<String> visitedFolders = new Set<String>();
    Integer maxFolderVisits = 40;
    while (!folderQueue.isEmpty() && visitedFolders.size() < maxFolderVisits) {
      String folderId = folderQueue.remove(0);
      if (String.isBlank(folderId) || visitedFolders.contains(folderId)) {
        continue;
      }
      visitedFolders.add(folderId);

      Map<String, Object> body = new Map<String, Object>{
        'parentId' => folderId,
        'onlyVisible' => false,
        'fields' => 'id,name,type,parentId,centroid,numberOfChildShapes',
        'featureCollection' => true
      };
      HttpResponse res = postGetShapes(body);
      if (res.getStatusCode() != 200) {
        throw new PSM_GeoShapeApiException('getshapes parentId failed: HTTP ' + res.getStatusCode());
      }
      List<Map<String, Object>> feats = extractFeatures(res.getBody());
      for (Map<String, Object> feature : feats) {
        String sid = getFeatureId(feature);
        String type = getFeatureType(feature);
        if (isFolderType(type)) {
          if (!String.isBlank(sid) && !visitedFolders.contains(sid)) {
            folderQueue.add(sid);
          }
        } else {
          if (!String.isBlank(sid) && !seenShapeIds.contains(sid)) {
            accumulated.add(feature);
            seenShapeIds.add(sid);
          }
        }
      }
    }
    return convertFeaturesToSummaries(accumulated, missingCenterIds);
  }

  private static List<ShapeSummary> convertFeaturesToSummaries(List<Map<String, Object>> features, List<String> missingCenterIds) {
    List<ShapeSummary> out = new List<ShapeSummary>();
    Set<String> seenIds = new Set<String>();
    for (Map<String, Object> feature : features) {
      String sid = getFeatureId(feature);
      if (String.isBlank(sid)) {
        continue;
      }
      if (seenIds.contains(sid)) {
        continue;
      }
      String type = getFeatureType(feature);
      if (isFolderType(type)) {
        continue;
      }
      LatLngPair c = extractCentroid(feature);
      if (c == null) {
        c = extractBBoxCenter(feature);
      }
      if (c == null) {
        missingCenterIds.add(sid);
        continue;
      }
      ShapeSummary row = new ShapeSummary(sid, c.lat, c.lng, getFeatureParentId(feature), type);
      Object noc = null;
      if (feature.get('properties') instanceof Map<String, Object>) {
        Map<String, Object> p = (Map<String, Object>) feature.get('properties');
        noc = p.get('numberOfChildShapes');
      }
      if (noc != null) {
        try {
          row.numberOfChildShapes = Integer.valueOf(String.valueOf(noc));
        } catch (Exception ignore) {
        }
      }
      out.add(row);
      seenIds.add(sid);
    }
    return out;
  }

  /** Public for rollup: folder-ish catalog types. */
  public static Boolean isFolderShapeType(String shapeType) {
    return isFolderType(shapeType);
  }

  /**
   * Loads GeoJSON geometry for shape ids (batched).
   */
  public static Map<String, Object> buildFeatureCollectionForIds(List<String> shapeIds) {
    Map<String, Object> root = new Map<String, Object>();
    root.put('type', 'FeatureCollection');
    List<Object> allFeatures = new List<Object>();
    if (shapeIds == null || shapeIds.isEmpty()) {
      root.put('features', allFeatures);
      return root;
    }
    Integer i = 0;
    while (i < shapeIds.size()) {
      Integer chunkEnd = Math.min(i + GEOMETRY_CHUNK_SIZE, shapeIds.size());
      List<String> chunk = new List<String>();
      for (Integer k = i; k < chunkEnd; k++) {
        chunk.add(shapeIds[k]);
      }
      Map<String, Object> body = new Map<String, Object>{
        'id' => String.join(chunk, ','),
        'simplifyTolerance' => 0.0001,
        'fields' => 'id,name,geometry,type,centroid',
        'featureCollection' => true,
        'dissolve' => false
      };
      HttpResponse res = postGetShapes(body);
      if (res.getStatusCode() != 200) {
        throw new PSM_GeoShapeApiException('getshapes by id failed: HTTP ' + res.getStatusCode());
      }
      List<Map<String, Object>> features = extractFeatures(res.getBody());
      for (Map<String, Object> f : features) {
        allFeatures.add(f);
      }
      i = chunkEnd;
    }
    root.put('features', allFeatures);
    return root;
  }

  /**
   * One-shot folder load via Salesforce folder linkage:
   * query shape records by folder id, then fetch geometry by shape ids.
   */
  public static Map<String, Object> buildFeatureCollectionForFolder(String parentFolderId) {
    if (String.isBlank(parentFolderId)) {
      Map<String, Object> empty = new Map<String, Object>();
      empty.put('type', 'FeatureCollection');
      empty.put('features', new List<Object>());
      return empty;
    }
    List<String> ids = listShapeIdsByExactFolder(parentFolderId);
    Map<String, Object> fromShapeIds = buildFeatureCollectionForIds(ids);
    if (hasAnyFeatures(fromShapeIds)) {
      return fromShapeIds;
    }

    // Some orgs store territory composition as child shape ids in Lat_Lng buckets.
    // Build one dissolved feature per shape record so map output stays at territory level.
    return buildDissolvedTerritoryFeaturesByFolder(parentFolderId);
  }

  private static List<String> listShapeIdsByExactFolder(String folderId) {
    if (String.isBlank(folderId)) {
      return new List<String>();
    }
    try {
      List<String> out = new List<String>();
      Set<String> seenShapeIds = new Set<String>();
      Integer maxRows = 5000;
      for (SObject row : (new ShapeSoqlGateway()).queryByFolderIds(new List<String>{ folderId })) {
        String sid = resolveRenderableShapeId(row);
        if (String.isBlank(sid) || seenShapeIds.contains(sid)) {
          continue;
        }
        String type = (String) row.get('geopointe__Type__c');
        if (isFolderType(type)) {
          continue;
        }
        out.add(sid);
        seenShapeIds.add(sid);
        if (out.size() >= maxRows) {
          break;
        }
      }
      return out;
    } catch (Exception ignore) {
      return new List<String>();
    }
  }

  private static String resolveRenderableShapeId(SObject row) {
    if (row == null) {
      return null;
    }
    String geopointeIdField = getGeopointeShapeIdFieldApiName();
    if (!String.isBlank(geopointeIdField)) {
      Object v = row.get(geopointeIdField);
      if (v != null && !String.isBlank(String.valueOf(v))) {
        return String.valueOf(v).trim();
      }
    }
    Object sfid = row.get('Id');
    return sfid == null ? null : String.valueOf(sfid);
  }

  private static Boolean hasAnyFeatures(Map<String, Object> featureCollection) {
    if (featureCollection == null) {
      return false;
    }
    Object features = featureCollection.get('features');
    return features instanceof List<Object> && !((List<Object>) features).isEmpty();
  }

  private static List<String> listChildShapeIdsByExactFolder(String folderId) {
    if (String.isBlank(folderId)) {
      return new List<String>();
    }
    List<String> out = new List<String>();
    Set<String> seen = new Set<String>();
    Integer maxRows = 5000;
    Integer maxIds = MAX_FOLDER_FALLBACK_CHILD_IDS;
    try {
      for (SObject row : (new ShapeSoqlGateway()).queryByFolderIds(new List<String>{ folderId })) {
        for (String childId : extractChildShapeIdsFromCoordinateFields(row)) {
          if (String.isBlank(childId) || seen.contains(childId)) {
            continue;
          }
          seen.add(childId);
          out.add(childId);
          if (out.size() >= maxIds) {
            return out;
          }
        }
        if (--maxRows <= 0) {
          break;
        }
      }
    } catch (Exception ignore) {
      return new List<String>();
    }
    return out;
  }

  private static Map<String, Object> buildDissolvedTerritoryFeaturesByFolder(String folderId) {
    Map<String, Object> root = new Map<String, Object>();
    root.put('type', 'FeatureCollection');
    List<Object> allFeatures = new List<Object>();
    root.put('features', allFeatures);
    if (String.isBlank(folderId)) {
      return root;
    }
    try {
      Integer maxRows = 5000;
      for (SObject row : (new ShapeSoqlGateway()).queryByFolderIds(new List<String>{ folderId })) {
        String type = (String) row.get('geopointe__Type__c');
        if (isFolderType(type)) {
          continue;
        }
        List<String> childIds = extractChildShapeIdsFromCoordinateFields(row);
        if (childIds.isEmpty()) {
          continue;
        }
        Map<String, Object> body = new Map<String, Object>{
          'id' => String.join(childIds, ','),
          'simplifyTolerance' => 0.0001,
          'fields' => 'id,name,geometry,type,centroid',
          'featureCollection' => true,
          'dissolve' => true
        };
        HttpResponse res = postGetShapes(body);
        if (res.getStatusCode() != 200) {
          continue;
        }
        List<Map<String, Object>> features = extractFeatures(res.getBody());
        for (Map<String, Object> feature : features) {
          applyTerritoryProperties(feature, row);
          allFeatures.add(feature);
        }
        if (--maxRows <= 0) {
          break;
        }
      }
    } catch (Exception ignore) {
      // Return partial/all empty feature collection on fallback failure.
    }
    return root;
  }

  private static void applyTerritoryProperties(Map<String, Object> feature, SObject row) {
    if (feature == null || row == null) {
      return;
    }
    Map<String, Object> props;
    Object p = feature.get('properties');
    if (p instanceof Map<String, Object>) {
      props = (Map<String, Object>) p;
    } else {
      props = new Map<String, Object>();
      feature.put('properties', props);
    }
    String sfId = row.get('Id') == null ? null : String.valueOf(row.get('Id'));
    if (!String.isBlank(sfId)) {
      props.put('shapeRecordId', sfId);
      props.put('id', sfId);
    }
    Object nameObj = row.get('Name');
    if (nameObj != null && !String.isBlank(String.valueOf(nameObj))) {
      props.put('name', String.valueOf(nameObj));
    }
    String colorHex = normalizeHexColor(row.get('geopointe__Color__c'));
    if (!String.isBlank(colorHex)) {
      props.put('color', colorHex);
    }
    LatLngPair c = extractCentroid(feature);
    if (c == null) {
      c = extractBBoxCenter(feature);
    }
    if (c != null) {
      props.put('centroidLat', c.lat);
      props.put('centroidLng', c.lng);
    }
  }

  private static String normalizeHexColor(Object raw) {
    if (raw == null) {
      return null;
    }
    String s = String.valueOf(raw).trim();
    if (String.isBlank(s)) {
      return null;
    }
    if (s.startsWith('#')) {
      s = s.substring(1);
    }
    if (!Pattern.matches('(?i)^[0-9a-f]{6}$', s)) {
      return null;
    }
    return '#' + s.toUpperCase();
  }

  private static List<String> extractChildShapeIdsFromCoordinateFields(SObject row) {
    List<String> out = new List<String>();
    if (row == null) {
      return out;
    }
    Set<String> seen = new Set<String>();
    Pattern tokenPattern = Pattern.compile('\\b[A-Z]{2}-[A-Z]{2}-[A-Z0-9]{2,12}\\b');
    Integer consecutiveBlanks = 0;
    for (String fieldApiName : getCoordinateFieldApiNames()) {
      Object raw = row.get(fieldApiName);
      if (raw == null || String.isBlank(String.valueOf(raw))) {
        consecutiveBlanks++;
        if (consecutiveBlanks >= 1 && looksLikeLatLngBucket(fieldApiName)) {
          break;
        }
        continue;
      }
      consecutiveBlanks = 0;
      Matcher m = tokenPattern.matcher(String.valueOf(raw));
      while (m.find()) {
        String token = m.group(0);
        if (!String.isBlank(token) && !seen.contains(token)) {
          seen.add(token);
          out.add(token);
        }
      }
    }
    return out;
  }

  public static List<Map<String, Object>> extractFeatures(String responseBody) {
    if (String.isBlank(responseBody)) {
      return new List<Map<String, Object>>();
    }
    Object parsed = JSON.deserializeUntyped(responseBody);
    if (!(parsed instanceof Map<String, Object>)) {
      return new List<Map<String, Object>>();
    }
    Map<String, Object> root = (Map<String, Object>) parsed;
    if (isGeopointeErrorEnvelope(root)) {
      return new List<Map<String, Object>>();
    }
    Object gs = root.get('geoShapes');
    if (!(gs instanceof Map<String, Object>)) {
      return new List<Map<String, Object>>();
    }
    Map<String, Object> geoShapes = (Map<String, Object>) gs;
    Object feats = geoShapes.get('features');
    if (!(feats instanceof List<Object>)) {
      return new List<Map<String, Object>>();
    }
    List<Map<String, Object>> out = new List<Map<String, Object>>();
    for (Object o : (List<Object>) feats) {
      if (o instanceof Map<String, Object>) {
        out.add((Map<String, Object>) o);
      }
    }
    return out;
  }

  /** Geopointe may return HTTP 200 with JSON body { statusCode: 400, message: ... } and no geoShapes. */
  private static Boolean isGeopointeErrorEnvelope(Map<String, Object> root) {
    if (root == null || !root.containsKey('statusCode')) {
      return false;
    }
    Integer code = coerceToInteger(root.get('statusCode'));
    if (code == null) {
      return false;
    }
    return code < 200 || code > 299;
  }

  private static Integer coerceToInteger(Object value) {
    if (value == null) {
      return null;
    }
    if (value instanceof Integer) {
      return (Integer) value;
    }
    if (value instanceof Long) {
      return ((Long) value).intValue();
    }
    if (value instanceof Decimal) {
      return ((Decimal) value).intValue();
    }
    try {
      return Integer.valueOf(String.valueOf(value));
    } catch (Exception ignore) {
      return null;
    }
  }

  private static String getFeatureId(Map<String, Object> feature) {
    Object props = feature.get('properties');
    if (props instanceof Map<String, Object>) {
      Map<String, Object> p = (Map<String, Object>) props;
      Object id = p.get('id');
      if (id != null) {
        return String.valueOf(id);
      }
    }
    return null;
  }

  private static String getFeatureName(Map<String, Object> feature) {
    Object props = feature.get('properties');
    if (props instanceof Map<String, Object>) {
      Map<String, Object> p = (Map<String, Object>) props;
      Object n = p.get('name');
      if (n != null) {
        return String.valueOf(n);
      }
    }
    return null;
  }

  private static String getFeatureParentId(Map<String, Object> feature) {
    Object props = feature.get('properties');
    if (props instanceof Map<String, Object>) {
      Map<String, Object> p = (Map<String, Object>) props;
      Object pid = p.get('parentId');
      if (pid != null) {
        return String.valueOf(pid);
      }
    }
    return null;
  }

  private static String getFeatureType(Map<String, Object> feature) {
    Object props = feature.get('properties');
    if (props instanceof Map<String, Object>) {
      Map<String, Object> p = (Map<String, Object>) props;
      Object t = p.get('type');
      if (t != null) {
        return String.valueOf(t);
      }
    }
    return null;
  }

  private static LatLngPair extractCentroid(Map<String, Object> feature) {
    Object c = feature.get('centroid');
    if (!(c instanceof Map<String, Object>)) {
      return null;
    }
    Map<String, Object> centroid = (Map<String, Object>) c;
    Object coords = centroid.get('coordinates');
    if (!(coords instanceof List<Object>)) {
      return null;
    }
    List<Object> coordList = (List<Object>) coords;
    if (coordList.size() < 2) {
      return null;
    }
    Decimal lng = toDecimal(coordList[0]);
    Decimal lat = toDecimal(coordList[1]);
    if (lat == null || lng == null) {
      return null;
    }
    return new LatLngPair(lat, lng);
  }

  /**
   * GeoJSON bbox on feature: [minLng, minLat, maxLng, maxLat]
   */
  private static LatLngPair extractBBoxCenter(Map<String, Object> feature) {
    Object bb = feature.get('bbox');
    if (!(bb instanceof List<Object>)) {
      return null;
    }
    List<Object> bbox = (List<Object>) bb;
    if (bbox.size() < 4) {
      return null;
    }
    Decimal minLng = toDecimal(bbox[0]);
    Decimal minLat = toDecimal(bbox[1]);
    Decimal maxLng = toDecimal(bbox[2]);
    Decimal maxLat = toDecimal(bbox[3]);
    if (minLng == null || minLat == null || maxLng == null || maxLat == null) {
      return null;
    }
    return new LatLngPair((minLat + maxLat) / 2, (minLng + maxLng) / 2);
  }

  private static Decimal toDecimal(Object o) {
    if (o == null) {
      return null;
    }
    if (o instanceof Decimal) {
      return (Decimal) o;
    }
    if (o instanceof Integer) {
      return Decimal.valueOf(String.valueOf((Integer) o));
    }
    if (o instanceof Long) {
      return Decimal.valueOf(String.valueOf((Long) o));
    }
    if (o instanceof Double) {
      return Decimal.valueOf(String.valueOf((Double) o));
    }
    return Decimal.valueOf(String.valueOf(o));
  }

  private static Integer scoreCandidate(String requested, String nameNorm, String id, String type) {
    String typeNorm = normalize(type);
    Boolean folderish = !String.isBlank(typeNorm) && typeNorm.contains('folder');

    if (!String.isBlank(id) && normalize(id) == requested) {
      return folderish ? 120 : 100;
    }
    if (!String.isBlank(nameNorm) && nameNorm == requested) {
      return folderish ? 90 : 80;
    }
    if (!String.isBlank(nameNorm) && nameNorm.contains(requested)) {
      return folderish ? 70 : 60;
    }
    if (!String.isBlank(nameNorm) && requested.contains(nameNorm)) {
      return folderish ? 50 : 40;
    }
    return -1;
  }

  private static Boolean isFolderType(String type) {
    String t = normalize(type);
    return !String.isBlank(t) && t.contains('folder');
  }

  private static String normalize(String value) {
    if (String.isBlank(value)) {
      return '';
    }
    return value.trim().toLowerCase();
  }

  private static String truncate(String value, Integer maxLen) {
    if (value == null) {
      return null;
    }
    if (value.length() <= maxLen) {
      return value;
    }
    return value.substring(0, maxLen) + '...';
  }

  private class LatLngPair {
    public Decimal lat;
    public Decimal lng;
    public LatLngPair(Decimal latitude, Decimal longitude) {
      this.lat = latitude;
      this.lng = longitude;
    }
  }

  public class PSM_GeoShapeApiException extends Exception {
  }

  @TestVisible
  static List<ShapeSummary> testListSummaries(String folderRootId) {
    return listShapeSummariesForParent(folderRootId);
  }
}
