@IsTest
private class PSM_GeoShapeApiService_Test {
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
