@IsTest
private class PSM_GeoShapeApiService_Test {
  private static SObject buildShapeRow(
    String idValue,
    String nameValue,
    String folderId,
    String typeValue,
    Decimal centerLat,
    Decimal centerLng,
    Decimal latMin,
    Decimal latMax,
    Decimal lngMin,
    Decimal lngMax,
    String colorValue,
    String latLngPayload
  ) {
    Map<String, SObjectType> gd = Schema.getGlobalDescribe();
    if (!gd.containsKey('geopointe__Shape__c')) {
      return null;
    }
    SObject row = gd.get('geopointe__Shape__c').newSObject();
    Map<String, Schema.SObjectField> fields = row.getSObjectType().getDescribe().fields.getMap();
    if (fields.containsKey('Id')) {
      row.put('Id', idValue);
    }
    if (fields.containsKey('Name')) {
      row.put('Name', nameValue);
    }
    if (fields.containsKey('geopointe__Folder__c')) {
      row.put('geopointe__Folder__c', folderId);
    }
    if (fields.containsKey('geopointe__Type__c')) {
      row.put('geopointe__Type__c', typeValue);
    }
    if (fields.containsKey('geopointe__Center__Latitude__s')) {
      row.put('geopointe__Center__Latitude__s', centerLat);
    }
    if (fields.containsKey('geopointe__Center__Longitude__s')) {
      row.put('geopointe__Center__Longitude__s', centerLng);
    }
    if (fields.containsKey('geopointe__Lat_Min__c')) {
      row.put('geopointe__Lat_Min__c', latMin);
    }
    if (fields.containsKey('geopointe__Lat_Max__c')) {
      row.put('geopointe__Lat_Max__c', latMax);
    }
    if (fields.containsKey('geopointe__Lng_Min__c')) {
      row.put('geopointe__Lng_Min__c', lngMin);
    }
    if (fields.containsKey('geopointe__Lng_Max__c')) {
      row.put('geopointe__Lng_Max__c', lngMax);
    }
    if (fields.containsKey('geopointe__Color__c')) {
      row.put('geopointe__Color__c', colorValue);
    }
    if (fields.containsKey('geopointe__Lat_Lng_1__c')) {
      row.put('geopointe__Lat_Lng_1__c', latLngPayload);
    }
    return row;
  }

  @IsTest
  static void testExtractFeaturesEmpty() {
    List<Map<String, Object>> feats = PSM_GeoShapeApiService.extractFeatures('{}');
    System.assertEquals(0, feats.size());
  }

  @IsTest
  static void testExtractFeaturesWithCollection() {
    String body =
      '{"geoShapes":{"type":"FeatureCollection","features":[' +
      '{"type":"Feature","properties":{"id":"a1"}}' +
      ']}}';
    List<Map<String, Object>> feats = PSM_GeoShapeApiService.extractFeatures(body);
    System.assertEquals(1, feats.size());
  }

  @IsTest
  static void testExtractFeaturesIgnoresHttp200ErrorEnvelope() {
    String body = '{"statusCode":400,"error":"Bad Request","message":"body/topParentId must be number"}';
    List<Map<String, Object>> feats = PSM_GeoShapeApiService.extractFeatures(body);
    System.assertEquals(0, feats.size());
  }

  @IsTest
  static void testExtractFeaturesHandlesNonMapRoot() {
    List<Map<String, Object>> feats = PSM_GeoShapeApiService.extractFeatures('[]');
    System.assertEquals(0, feats.size());
  }

  @IsTest
  static void testExtractFeaturesStatusCodeStringAndMixedFeatureList() {
    String errBody = '{"statusCode":"500","message":"fail"}';
    System.assertEquals(0, PSM_GeoShapeApiService.extractFeatures(errBody).size());

    String mixedBody =
      '{"geoShapes":{"type":"FeatureCollection","features":[' +
      '"not-a-map",' +
      '{"type":"Feature","properties":{"id":"a2"}}' +
      ']}}';
    List<Map<String, Object>> feats = PSM_GeoShapeApiService.extractFeatures(mixedBody);
    System.assertEquals(1, feats.size());
  }

  private class SearchNoMatchMock implements HttpCalloutMock {
    public HTTPResponse respond(HTTPRequest req) {
      HttpResponse res = new HttpResponse();
      res.setStatusCode(200);
      res.setBody('{"geoShapes":{"type":"FeatureCollection","features":[]}}');
      return res;
    }
  }

  @IsTest
  static void testResolveFolderIdThrowsWhenNoExactName() {
    Test.setMock(HttpCalloutMock.class, new SearchNoMatchMock());
    try {
      PSM_GeoShapeApiService.resolveFolderId('Replace_With_Folder_Name');
      System.assert(false, 'Expected exception');
    } catch (PSM_GeoShapeApiService.PSM_GeoShapeApiException e) {
      System.assert(e.getMessage().contains('No folder found'));
    }
  }

  @IsTest
  static void testResolveFolderIdRequiresName() {
    try {
      PSM_GeoShapeApiService.resolveFolderId(null);
      System.assert(false, 'Expected exception');
    } catch (PSM_GeoShapeApiService.PSM_GeoShapeApiException e) {
      System.assert(e.getMessage().contains('required'));
    }
  }

  private class FolderSearchMock implements HttpCalloutMock {
    public HTTPResponse respond(HTTPRequest req) {
      HttpResponse res = new HttpResponse();
      res.setStatusCode(200);
      res.setBody(
        '{"geoShapes":{"type":"FeatureCollection","features":[' +
          '{"type":"Feature","properties":{"id":"fld-xyz","name":"TargetFolder","type":"Folder"}}' +
          ']}}'
      );
      return res;
    }
  }

  @IsTest
  static void testResolveFolderIdSuccess() {
    Test.setMock(HttpCalloutMock.class, new FolderSearchMock());
    System.assertEquals('fld-xyz', PSM_GeoShapeApiService.resolveFolderId('TargetFolder'));
  }

  private class SearchHttpErrorMock implements HttpCalloutMock {
    public HTTPResponse respond(HTTPRequest req) {
      HttpResponse res = new HttpResponse();
      res.setStatusCode(503);
      res.setStatus('Service Unavailable');
      res.setBody('{"message":"down"}');
      return res;
    }
  }

  @IsTest
  static void testResolveFolderIdThrowsOnSearchHttpFailure() {
    Test.setMock(HttpCalloutMock.class, new SearchHttpErrorMock());
    try {
      PSM_GeoShapeApiService.resolveFolderId('TargetFolder');
      System.assert(false, 'Expected exception');
    } catch (PSM_GeoShapeApiService.PSM_GeoShapeApiException e) {
      System.assert(e.getMessage().contains('getshapes search failed'));
    }
  }

  private class SearchEmptyTraversalFindsFolderMock implements HttpCalloutMock {
    public HTTPResponse respond(HTTPRequest req) {
      HttpResponse res = new HttpResponse();
      res.setStatusCode(200);
      String b = req.getBody() == null ? '' : req.getBody();
      if (b.contains('"search"')) {
        res.setBody('{"geoShapes":{"type":"FeatureCollection","features":[]}}');
      } else if (b.contains('"parentId":"root-1"')) {
        res.setBody(
          '{"geoShapes":{"type":"FeatureCollection","features":[' +
            '{"type":"Feature","properties":{"id":"target-id","name":"PublicShapeMap","type":"Folder","parentId":"root-1"}}' +
            ']}}'
        );
      } else {
        res.setBody(
          '{"geoShapes":{"type":"FeatureCollection","features":[' +
            '{"type":"Feature","properties":{"id":"root-1","name":"Root","type":"Folder"}}' +
            ']}}'
        );
      }
      return res;
    }
  }

  @IsTest
  static void testResolveFolderIdFallsBackToTraversalWhenSearchEmpty() {
    Test.setMock(HttpCalloutMock.class, new SearchEmptyTraversalFindsFolderMock());
    System.assertEquals('target-id', PSM_GeoShapeApiService.resolveFolderId('PublicShapeMap'));
  }

  private class SearchSamplesButNoMatchMock implements HttpCalloutMock {
    public HTTPResponse respond(HTTPRequest req) {
      HttpResponse res = new HttpResponse();
      res.setStatusCode(200);
      String b = req.getBody() == null ? '' : req.getBody();
      if (b.contains('"search"')) {
        res.setBody(
          '{"geoShapes":{"type":"FeatureCollection","features":[' +
          '{"type":"Feature","properties":{"id":"f-1","name":"Alpha Folder","type":"Folder"}},' +
          '{"type":"Feature","properties":{"id":"f-2","name":"Beta Folder","type":"Folder"}}' +
          ']}}'
        );
      } else {
        res.setBody('{"geoShapes":{"type":"FeatureCollection","features":[]}}');
      }
      return res;
    }
  }

  @IsTest
  static void testResolveFolderIdThrowsWithSampleNamesWhenNoMatch() {
    Test.setMock(HttpCalloutMock.class, new SearchSamplesButNoMatchMock());
    try {
      PSM_GeoShapeApiService.resolveFolderId('NoSuchFolder');
      System.assert(false, 'Expected exception');
    } catch (PSM_GeoShapeApiService.PSM_GeoShapeApiException e) {
      System.assert(e.getMessage().contains('No folder match'));
      System.assert(e.getMessage().contains('Search/traversal sample'));
    }
  }

  @IsTest
  static void testIsFolderShapeType() {
    System.assertEquals(true, PSM_GeoShapeApiService.isFolderShapeType('Folder'));
    System.assertEquals(true, PSM_GeoShapeApiService.isFolderShapeType('My Folder'));
    System.assertEquals(false, PSM_GeoShapeApiService.isFolderShapeType('Polygon'));
  }

  private class TopEmptyThenParentMock implements HttpCalloutMock {
    Integer call = 0;
    public HTTPResponse respond(HTTPRequest req) {
      HttpResponse res = new HttpResponse();
      res.setStatusCode(200);
      call++;
      if (req.getBody() != null && req.getBody().contains('"topParentId"')) {
        res.setBody('{"geoShapes":{"type":"FeatureCollection","features":[]}}');
      } else {
        res.setBody(
          '{"geoShapes":{"type":"FeatureCollection","features":[' +
            '{"type":"Feature","properties":{"id":"poly-1","type":"Polygon","parentId":"fld-1"},' +
            '"centroid":{"type":"Point","coordinates":[-100.0,40.0]}}' +
            ']}}'
        );
      }
      return res;
    }
  }

  @IsTest
  static void testListSummariesFallsBackWhenTopParentEmpty() {
    Test.setMock(HttpCalloutMock.class, new TopEmptyThenParentMock());
    // Non-numeric id: no topParentId call; folder expansion lists immediate children of fld-1.
    List<PSM_GeoShapeApiService.ShapeSummary> rows = PSM_GeoShapeApiService.testListSummaries('fld-1');
    System.assertEquals(1, rows.size());
    System.assertEquals('poly-1', rows[0].id);
    System.assertEquals('fld-1', rows[0].parentId);
  }

  private class NestedFolderBfsMock implements HttpCalloutMock {
    public HTTPResponse respond(HTTPRequest req) {
      HttpResponse res = new HttpResponse();
      res.setStatusCode(200);
      String b = req.getBody() == null ? '' : req.getBody();
      if (b.contains('"parentId":"a0ROOTFOLDER00001"')) {
        res.setBody(
          '{"geoShapes":{"type":"FeatureCollection","features":[' +
            '{"type":"Feature","properties":{"id":"sub-f","name":"Nested","type":"Folder"}}' +
            ']}}'
        );
      } else if (b.contains('"parentId":"sub-f"')) {
        res.setBody(
          '{"geoShapes":{"type":"FeatureCollection","features":[' +
            '{"type":"Feature","properties":{"id":"poly-deep","type":"Polygon","parentId":"sub-f"},' +
            '"centroid":{"type":"Point","coordinates":[-100.0,40.0]}}' +
            ']}}'
        );
      } else {
        res.setBody('{"geoShapes":{"type":"FeatureCollection","features":[]}}');
      }
      return res;
    }
  }

  @IsTest
  static void testListSummariesExpandsNestedFolders() {
    Test.setMock(HttpCalloutMock.class, new NestedFolderBfsMock());
    List<PSM_GeoShapeApiService.ShapeSummary> rows = PSM_GeoShapeApiService.testListSummaries('a0ROOTFOLDER00001');
    System.assertEquals(1, rows.size());
    System.assertEquals('poly-deep', rows[0].id);
  }

  private class BackfillGeometryMock implements HttpCalloutMock {
    public HTTPResponse respond(HTTPRequest req) {
      HttpResponse res = new HttpResponse();
      res.setStatusCode(200);
      String b = req.getBody();
      if (b != null && b.contains('"topParentId"')) {
        res.setBody(
          '{"geoShapes":{"type":"FeatureCollection","features":[' +
            '{"type":"Feature","properties":{"id":"no-centroid","type":"Polygon","parentId":"fld-2"}}' +
            ']}}'
        );
      } else if (b != null && b.contains('"simplifyTolerance"')) {
        res.setBody(
          '{"geoShapes":{"type":"FeatureCollection","features":[' +
            '{"type":"Feature","properties":{"id":"no-centroid","type":"Polygon"},' +
            '"bbox":[-100.0,39.0,-99.0,40.0]}' +
            ']}}'
        );
      } else {
        res.setBody('{"geoShapes":{"type":"FeatureCollection","features":[]}}');
      }
      return res;
    }
  }

  @IsTest
  static void testListSummariesBackfillsCenterFromBboxGeometry() {
    Test.setMock(HttpCalloutMock.class, new BackfillGeometryMock());
    // Numeric id triggers topParentId path (Geopointe API contract).
    List<PSM_GeoShapeApiService.ShapeSummary> rows = PSM_GeoShapeApiService.testListSummaries('12345');
    System.assertEquals(1, rows.size());
    System.assertEquals('no-centroid', rows[0].id);
    System.assertNotEquals(null, rows[0].lat);
    System.assertNotEquals(null, rows[0].lng);
  }

  private class ChunkGeometryMock implements HttpCalloutMock {
    public HTTPResponse respond(HTTPRequest req) {
      HttpResponse res = new HttpResponse();
      res.setStatusCode(200);
      Map<String, Object> parsed = (Map<String, Object>) JSON.deserializeUntyped(req.getBody());
      String ids = (String) parsed.get('id');
      List<String> parts = ids.split(',');
      List<String> featParts = new List<String>();
      for (String p : parts) {
        featParts.add(
          '{"type":"Feature","properties":{"id":"' +
            p +
            '","type":"Polygon"},' +
            '"geometry":{"type":"Polygon","coordinates":[[[-100,39],[-99,39],[-99,40],[-100,40],[-100,39]]]}}'
        );
      }
      res.setBody(
        '{"geoShapes":{"type":"FeatureCollection","features":[' + String.join(featParts, ',') + ']}}'
      );
      return res;
    }
  }

  @IsTest
  static void testBuildFeatureCollectionChunksIds() {
    Test.setMock(HttpCalloutMock.class, new ChunkGeometryMock());
    List<String> ids = new List<String>();
    for (Integer i = 0; i < 21; i++) {
      ids.add('s' + i);
    }
    Map<String, Object> fc = PSM_GeoShapeApiService.buildFeatureCollectionForIds(ids);
    List<Object> feats = (List<Object>) fc.get('features');
    System.assertEquals(21, feats.size());
  }

  private class GeometryHttpErrorMock implements HttpCalloutMock {
    public HTTPResponse respond(HTTPRequest req) {
      HttpResponse res = new HttpResponse();
      res.setStatusCode(500);
      res.setBody('{"message":"error"}');
      return res;
    }
  }

  @IsTest
  static void testBuildFeatureCollectionForIdsThrowsOnHttpError() {
    Test.setMock(HttpCalloutMock.class, new GeometryHttpErrorMock());
    try {
      PSM_GeoShapeApiService.buildFeatureCollectionForIds(new List<String>{ 'shape-1' });
      System.assert(false, 'Expected exception');
    } catch (PSM_GeoShapeApiService.PSM_GeoShapeApiException e) {
      System.assert(e.getMessage().contains('getshapes by id failed'));
    }
  }

  @IsTest
  static void testBuildFeatureCollectionForIdsEmptyList() {
    Map<String, Object> fc = PSM_GeoShapeApiService.buildFeatureCollectionForIds(new List<String>());
    List<Object> feats = (List<Object>) fc.get('features');
    System.assertEquals(0, feats.size());
  }

  @IsTest
  static void testBuildFeatureCollectionForFolderBlank() {
    Map<String, Object> fc = PSM_GeoShapeApiService.buildFeatureCollectionForFolder(null);
    List<Object> feats = (List<Object>) fc.get('features');
    System.assertEquals(0, feats.size());
  }

  private class FolderFeatureCollectionMock implements HttpCalloutMock {
    public HTTPResponse respond(HTTPRequest req) {
      Map<String, Object> body = (Map<String, Object>) JSON.deserializeUntyped(req.getBody());
      Boolean dissolve = body.containsKey('dissolve') ? (Boolean) body.get('dissolve') : false;
      HttpResponse res = new HttpResponse();
      res.setStatusCode(200);
      if (dissolve == true) {
        res.setBody(
          '{"geoShapes":{"type":"FeatureCollection","features":[' +
          '{"type":"Feature","bbox":[-101.0,39.0,-99.0,41.0]}' +
          ']}}'
        );
      } else {
        res.setBody(
          '{"geoShapes":{"type":"FeatureCollection","features":[' +
          '{"type":"Feature","properties":{"id":"sf-shape-1","type":"Polygon"},' +
          '"centroid":{"type":"Point","coordinates":[-100.0,40.0]}}' +
          ']}}'
        );
      }
      return res;
    }
  }

  @IsTest
  static void testBuildFeatureCollectionForFolderUsesShapeIdsPath() {
    SObject row = buildShapeRow(
      'a0A000000000008AAA',
      'Folder Loaded',
      'root',
      'Polygon',
      null,
      null,
      null,
      null,
      null,
      null,
      null,
      'CA-US-44444'
    );
    if (row == null) {
      System.assert(true, 'geopointe__Shape__c not available in this org test context.');
      return;
    }
    PSM_GeoShapeApiService.testShapeQueryRowsOverride = new List<SObject>{ row };
    Test.setMock(HttpCalloutMock.class, new FolderFeatureCollectionMock());
    try {
      Map<String, Object> fc = PSM_GeoShapeApiService.buildFeatureCollectionForFolder('root');
      List<Object> feats = (List<Object>) fc.get('features');
      System.assertEquals(1, feats.size());
    } finally {
      PSM_GeoShapeApiService.testShapeQueryRowsOverride = null;
    }
  }

  private class FolderFallbackDissolveMock implements HttpCalloutMock {
    public HTTPResponse respond(HTTPRequest req) {
      Map<String, Object> body = (Map<String, Object>) JSON.deserializeUntyped(req.getBody());
      Boolean dissolve = body.containsKey('dissolve') ? (Boolean) body.get('dissolve') : false;
      HttpResponse res = new HttpResponse();
      res.setStatusCode(200);
      if (dissolve == true) {
        res.setBody(
          '{"geoShapes":{"type":"FeatureCollection","features":[' +
          '{"type":"Feature","properties":{"type":"Polygon"},' +
          '"bbox":[-101.0,39.0,-99.0,41.0]}' +
          ']}}'
        );
      } else {
        res.setBody('{"geoShapes":{"type":"FeatureCollection","features":[]}}');
      }
      return res;
    }
  }

  @IsTest
  static void testBuildFeatureCollectionForFolderFallsBackToDissolve() {
    SObject row = buildShapeRow(
      'a0A000000000009AAA',
      'Needs Dissolve',
      'root',
      'Polygon',
      null,
      null,
      null,
      null,
      null,
      null,
      '0f0f0f',
      'CA-US-55555,CA-US-66666'
    );
    if (row == null) {
      System.assert(true, 'geopointe__Shape__c not available in this org test context.');
      return;
    }
    PSM_GeoShapeApiService.testShapeQueryRowsOverride = new List<SObject>{ row };
    Test.setMock(HttpCalloutMock.class, new FolderFallbackDissolveMock());
    try {
      Map<String, Object> fc = PSM_GeoShapeApiService.buildFeatureCollectionForFolder('root');
      List<Object> feats = (List<Object>) fc.get('features');
      System.assertEquals(1, feats.size());
      Map<String, Object> feature = (Map<String, Object>) feats[0];
      Map<String, Object> props = (Map<String, Object>) feature.get('properties');
      System.assertEquals('Needs Dissolve', props.get('name'));
      System.assertEquals('#0F0F0F', props.get('color'));
      System.assertNotEquals(null, props.get('centroidLat'));
      System.assertNotEquals(null, props.get('centroidLng'));
    } finally {
      PSM_GeoShapeApiService.testShapeQueryRowsOverride = null;
    }
  }

  @IsTest
  static void testListFolderShapeLoadSpecsForViewportInputValidation() {
    List<Map<String, Object>> a = PSM_GeoShapeApiService.listFolderShapeLoadSpecsForViewport(null, 0, 1, 0, 1);
    List<Map<String, Object>> b = PSM_GeoShapeApiService.listFolderShapeLoadSpecsForViewport('x', null, 1, 0, 1);
    System.assertEquals(0, a.size());
    System.assertEquals(0, b.size());
  }

  @IsTest
  static void testListFolderShapeLoadSpecsForViewportWideBounds() {
    PSM_Map_Config__mdt cfg = [
      SELECT Folder_Id__c
      FROM PSM_Map_Config__mdt
      LIMIT 1
    ];
    if (cfg == null || String.isBlank(cfg.Folder_Id__c)) {
      System.assert(true, 'No folder id configured in metadata for viewport query test.');
      return;
    }
    List<Map<String, Object>> specs = PSM_GeoShapeApiService.listFolderShapeLoadSpecsForViewport(
      cfg.Folder_Id__c,
      -90,
      90,
      -180,
      180
    );
    System.assertNotEquals(null, specs);
  }

  @IsTest
  static void testListFolderShapeLoadSpecsInputValidation() {
    List<Map<String, Object>> specs = PSM_GeoShapeApiService.listFolderShapeLoadSpecs(null);
    System.assertEquals(0, specs.size());
  }

  @IsTest
  static void testListFolderShapeLoadSpecsUsesInjectedRows() {
    SObject folder = buildShapeRow(
      'a0A000000000001AAA',
      'Folder One',
      'root',
      'Folder',
      null,
      null,
      null,
      null,
      null,
      null,
      null,
      null
    );
    SObject polygon = buildShapeRow(
      'a0A000000000002AAA',
      'Territory One',
      'root',
      'Polygon',
      null,
      null,
      null,
      null,
      null,
      null,
      'a1b2c3',
      'CA-US-12345 and NV-US-67890 and CA-US-12345'
    );
    if (folder == null || polygon == null) {
      System.assert(true, 'geopointe__Shape__c not available in this org test context.');
      return;
    }
    PSM_GeoShapeApiService.testShapeQueryRowsOverride = new List<SObject>{ folder, polygon };
    try {
      List<Map<String, Object>> specs = PSM_GeoShapeApiService.listFolderShapeLoadSpecs('root');
      System.assertEquals(1, specs.size());
      Map<String, Object> spec = specs[0];
      System.assertEquals('Territory One', spec.get('name'));
      System.assertEquals('#A1B2C3', spec.get('color'));
      List<Object> childIds = (List<Object>) spec.get('childIds');
      System.assertEquals(2, childIds.size());
    } finally {
      PSM_GeoShapeApiService.testShapeQueryRowsOverride = null;
    }
  }

  @IsTest
  static void testListFolderShapeLoadSpecsForViewportFiltersInjectedRows() {
    SObject outside = buildShapeRow(
      'a0A000000000003AAA',
      'Outside',
      'root',
      'Polygon',
      null,
      null,
      10,
      11,
      10,
      11,
      null,
      'CA-US-11111'
    );
    SObject insideCenter = buildShapeRow(
      'a0A000000000004AAA',
      'Inside Center',
      'root',
      'Polygon',
      40,
      -100,
      null,
      null,
      null,
      null,
      null,
      'CA-US-22222'
    );
    SObject unknownLocation = buildShapeRow(
      'a0A000000000005AAA',
      'Unknown Location',
      'root',
      'Polygon',
      null,
      null,
      null,
      null,
      null,
      null,
      null,
      'CA-US-33333'
    );
    if (outside == null || insideCenter == null || unknownLocation == null) {
      System.assert(true, 'geopointe__Shape__c not available in this org test context.');
      return;
    }
    PSM_GeoShapeApiService.testShapeQueryRowsOverride = new List<SObject>{ outside, insideCenter, unknownLocation };
    try {
      List<Map<String, Object>> specs = PSM_GeoShapeApiService.listFolderShapeLoadSpecsForViewport(
        'root',
        39,
        41,
        -101,
        -99
      );
      System.assertEquals(2, specs.size());
      Set<String> names = new Set<String>();
      for (Map<String, Object> spec : specs) {
        names.add(String.valueOf(spec.get('name')));
      }
      System.assertEquals(true, names.contains('Inside Center'));
      System.assertEquals(true, names.contains('Unknown Location'));
      System.assertEquals(false, names.contains('Outside'));
    } finally {
      PSM_GeoShapeApiService.testShapeQueryRowsOverride = null;
    }
  }

  @IsTest
  static void testListShapeSummariesForParentBlankInput() {
    List<PSM_GeoShapeApiService.ShapeSummary> rows = PSM_GeoShapeApiService.listShapeSummariesForParent(null);
    System.assertEquals(0, rows.size());
  }

  @IsTest
  static void testListShapeSummariesForParentUsesInjectedSalesforceRows() {
    SObject centerRow = buildShapeRow(
      'a0A000000000006AAA',
      'Center Row',
      'root',
      'Polygon',
      40,
      -100,
      null,
      null,
      null,
      null,
      null,
      null
    );
    SObject bboxRow = buildShapeRow(
      'a0A000000000007AAA',
      'BBox Row',
      'root',
      'Polygon',
      null,
      null,
      39,
      41,
      -101,
      -99,
      null,
      null
    );
    if (centerRow == null || bboxRow == null) {
      System.assert(true, 'geopointe__Shape__c not available in this org test context.');
      return;
    }
    PSM_GeoShapeApiService.testShapeQueryRowsOverride = new List<SObject>{ centerRow, bboxRow };
    try {
      List<PSM_GeoShapeApiService.ShapeSummary> rows = PSM_GeoShapeApiService.listShapeSummariesForParent('root');
      System.assertEquals(2, rows.size());
      for (PSM_GeoShapeApiService.ShapeSummary row : rows) {
        System.assertNotEquals(null, row.lat);
        System.assertNotEquals(null, row.lng);
      }
    } finally {
      PSM_GeoShapeApiService.testShapeQueryRowsOverride = null;
    }
  }

  private class MissingCenterBackfillMock implements HttpCalloutMock {
    public HTTPResponse respond(HTTPRequest req) {
      HttpResponse res = new HttpResponse();
      res.setStatusCode(200);
      res.setBody(
        '{"geoShapes":{"type":"FeatureCollection","features":[' +
        '{"type":"Feature","properties":{"id":"a0A000000000010AAA","type":"Polygon","parentId":"root"},' +
        '"bbox":[-104.0,39.0,-100.0,41.0]}' +
        ']}}'
      );
      return res;
    }
  }

  @IsTest
  static void testListShapeSummariesForParentBackfillsMissingCenterViaGeometry() {
    SObject missingCenter = buildShapeRow(
      'a0A000000000010AAA',
      'Backfill Needed',
      'root',
      'Polygon',
      null,
      null,
      null,
      null,
      null,
      null,
      null,
      null
    );
    if (missingCenter == null) {
      System.assert(true, 'geopointe__Shape__c not available in this org test context.');
      return;
    }
    PSM_GeoShapeApiService.testShapeQueryRowsOverride = new List<SObject>{ missingCenter };
    Test.setMock(HttpCalloutMock.class, new MissingCenterBackfillMock());
    try {
      List<PSM_GeoShapeApiService.ShapeSummary> rows = PSM_GeoShapeApiService.listShapeSummariesForParent('root');
      System.assertEquals(1, rows.size());
      System.assertEquals('a0A000000000010AAA', rows[0].id);
      System.assertNotEquals(null, rows[0].lat);
      System.assertNotEquals(null, rows[0].lng);
    } finally {
      PSM_GeoShapeApiService.testShapeQueryRowsOverride = null;
    }
  }

  private class SalesforceCatalogIdExpansionMock implements HttpCalloutMock {
    public HTTPResponse respond(HTTPRequest req) {
      HttpResponse res = new HttpResponse();
      res.setStatusCode(200);
      res.setBody(
        '{"geoShapes":{"type":"FeatureCollection","features":[' +
        '{"type":"Feature","properties":{"id":"poly-from-sf-id","type":"Polygon","parentId":"001ABCDEF123456789"},' +
        '"centroid":{"type":"Point","coordinates":[-95.0,33.0]}}' +
        ']}}'
      );
      return res;
    }
  }

  @IsTest
  static void testListSummariesTreatsSalesforceIdAsNonNumericTopParent() {
    Test.setMock(HttpCalloutMock.class, new SalesforceCatalogIdExpansionMock());
    List<PSM_GeoShapeApiService.ShapeSummary> rows = PSM_GeoShapeApiService.testListSummaries('001ABCDEF123456789');
    System.assertEquals(1, rows.size());
    System.assertEquals('poly-from-sf-id', rows[0].id);
  }

  private class FolderExpansionHttpErrorMock implements HttpCalloutMock {
    public HTTPResponse respond(HTTPRequest req) {
      HttpResponse res = new HttpResponse();
      String b = req.getBody() == null ? '' : req.getBody();
      if (b.contains('"parentId"')) {
        res.setStatusCode(500);
        res.setBody('{"message":"parent call failed"}');
      } else {
        res.setStatusCode(200);
        res.setBody('{"geoShapes":{"type":"FeatureCollection","features":[]}}');
      }
      return res;
    }
  }

  @IsTest
  static void testListSummariesThrowsWhenFolderExpansionCallFails() {
    Test.setMock(HttpCalloutMock.class, new FolderExpansionHttpErrorMock());
    try {
      PSM_GeoShapeApiService.testListSummaries('non-numeric-folder-id');
      System.assert(false, 'Expected exception');
    } catch (PSM_GeoShapeApiService.PSM_GeoShapeApiException e) {
      System.assert(e.getMessage().contains('parentId failed'));
    }
  }

  private class TopParentHttpErrorThenFallbackMock implements HttpCalloutMock {
    public HTTPResponse respond(HTTPRequest req) {
      HttpResponse res = new HttpResponse();
      String b = req.getBody() == null ? '' : req.getBody();
      if (b.contains('"topParentId"')) {
        res.setStatusCode(500);
        res.setBody('{"message":"top failed"}');
      } else {
        res.setStatusCode(200);
        res.setBody(
          '{"geoShapes":{"type":"FeatureCollection","features":[' +
          '{"type":"Feature","properties":{"id":"poly-fallback","type":"Polygon","parentId":"12345"},' +
          '"centroid":{"type":"Point","coordinates":[-101.0,39.5]}}' +
          ']}}'
        );
      }
      return res;
    }
  }

  @IsTest
  static void testListSummariesFallsBackWhenTopParentCallFails() {
    Test.setMock(HttpCalloutMock.class, new TopParentHttpErrorThenFallbackMock());
    List<PSM_GeoShapeApiService.ShapeSummary> rows = PSM_GeoShapeApiService.testListSummaries('12345');
    System.assertEquals(1, rows.size());
    System.assertEquals('poly-fallback', rows[0].id);
  }

  @IsTest
  static void testShapeSummaryConstructors() {
    PSM_GeoShapeApiService.ShapeSummary a = new PSM_GeoShapeApiService.ShapeSummary('id1', 1, 2);
    System.assertEquals('id1', a.id);
    System.assertEquals(1, a.lat);
    System.assertEquals(2, a.lng);

    PSM_GeoShapeApiService.ShapeSummary b = new PSM_GeoShapeApiService.ShapeSummary('id2', 3, 4, 'p1', 'Polygon');
    System.assertEquals('p1', b.parentId);
    System.assertEquals('Polygon', b.type);
  }

  @IsTest
  static void testGetClientHeaderMethods() {
    System.assertNotEquals(null, PSM_GeoShapeApiService.getClientHeaderUserId());
    System.assertNotEquals(null, PSM_GeoShapeApiService.getClientHeaderOrgId());
  }

  private class HeaderCaptureMock implements HttpCalloutMock {
    public HTTPResponse respond(HTTPRequest req) {
      System.assertEquals('005OVERRIDEUSER123', req.getHeader('x-user-id'));
      System.assertEquals('00DOVERRIDEORG456', req.getHeader('x-organization-id'));
      HttpResponse res = new HttpResponse();
      res.setStatusCode(200);
      res.setBody('{"geoShapes":{"type":"FeatureCollection","features":[]}}');
      return res;
    }
  }

  @IsTest
  static void testPostGetShapesUsesTestHeaderOverrides() {
    PSM_GeoShapeApiService.testOverrideHeaderUserId = '005OVERRIDEUSER123';
    PSM_GeoShapeApiService.testOverrideHeaderOrgId = '00DOVERRIDEORG456';
    Test.setMock(HttpCalloutMock.class, new HeaderCaptureMock());
    Test.startTest();
    PSM_GeoShapeApiService.postGetShapes(new Map<String, Object>{ 'parentId' => 'a0Aal00000EiccbEAB' });
    Test.stopTest();
    PSM_GeoShapeApiService.testOverrideHeaderUserId = null;
    PSM_GeoShapeApiService.testOverrideHeaderOrgId = null;
  }
}
