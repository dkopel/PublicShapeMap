@IsTest
private class PSM_MapController_Test {
  private class DissolveMock implements HttpCalloutMock {
    public HTTPResponse respond(HTTPRequest req) {
      HttpResponse res = new HttpResponse();
      res.setStatusCode(200);
      Map<String, Object> body = (Map<String, Object>) JSON.deserializeUntyped(req.getBody());
      String idsCsv = (String) body.get('id');
      String firstId = String.isBlank(idsCsv) ? 'shape-default' : idsCsv.split(',')[0];
      res.setBody(
        '{"geoShapes":{"type":"FeatureCollection","features":[' +
          '{"type":"Feature","properties":{"id":"' +
          firstId +
          '","type":"Polygon"},' +
          '"centroid":{"type":"Point","coordinates":[-100.0,40.0]},' +
          '"geometry":{"type":"Polygon","coordinates":[[[-106.0,39.0],[-103.0,39.0],[-103.0,41.0],[-106.0,41.0],[-106.0,39.0]]]}}' +
          ']}}'
      );
      return res;
    }
  }

  private class DissolveHttpErrorMock implements HttpCalloutMock {
    public HTTPResponse respond(HTTPRequest req) {
      HttpResponse res = new HttpResponse();
      res.setStatusCode(500);
      res.setBody('{"error":"boom"}');
      return res;
    }
  }

  @IsTest
  static void testGetMapBootstrap() {
    String responseJson = PSM_MapController.getMapBootstrap();
    Map<String, Object> payload = (Map<String, Object>) JSON.deserializeUntyped(responseJson);
    System.assertEquals(true, payload.get('success'), responseJson);
    System.assertNotEquals(null, payload.get('googleApiKey'));
  }

  @IsTest
  static void testGetVisibleShapesBelowConfiguredMinZoom() {
    String responseJson = PSM_MapController.getVisibleShapesForViewport(39, 41, -82, -79, 1);
    Map<String, Object> payload = (Map<String, Object>) JSON.deserializeUntyped(responseJson);
    System.assertEquals(true, payload.get('success'), responseJson);
    System.assertEquals(true, payload.get('belowMinZoom'), responseJson);
    System.assertEquals(0, payload.get('shapeCount'));
  }

  @IsTest
  static void testGetVisibleShapesAtOrAboveConfiguredMinZoom() {
    String responseJson = PSM_MapController.getVisibleShapesForViewport(39, 41, -82, -79, 99);
    Map<String, Object> payload = (Map<String, Object>) JSON.deserializeUntyped(responseJson);
    System.assertEquals(true, payload.get('success'), responseJson);
    System.assertEquals(false, payload.get('belowMinZoom'));
    System.assertNotEquals(null, payload.get('shapeSpecs'));
    System.assertNotEquals(null, payload.get('debug'));
  }

  @IsTest
  static void testGetAllShapesForFolderReturnsPayload() {
    String responseJson = PSM_MapController.getAllShapesForFolder();
    Map<String, Object> payload = (Map<String, Object>) JSON.deserializeUntyped(responseJson);
    System.assertEquals(true, payload.get('success'), responseJson);
    System.assertNotEquals(null, payload.get('shapeSpecs'));
    System.assertNotEquals(null, payload.get('shapeCount'));
  }

  @IsTest
  static void testGetDissolvedShapeGeometryReturnsFeatureCollection() {
    Test.setMock(HttpCalloutMock.class, new DissolveMock());
    Test.startTest();
    String responseJson = PSM_MapController.getDissolvedShapeGeometry('shape-1,shape-2');
    Test.stopTest();
    Map<String, Object> payload = (Map<String, Object>) JSON.deserializeUntyped(responseJson);
    System.assertEquals(true, payload.get('success'), responseJson);
    String responseBody = (String) payload.get('responseBody');
    System.assertNotEquals(null, responseBody);
    Map<String, Object> parsedBody = (Map<String, Object>) JSON.deserializeUntyped(responseBody);
    Map<String, Object> fc = (Map<String, Object>) parsedBody.get('geoShapes');
    List<Object> feats = (List<Object>) fc.get('features');
    System.assertEquals(1, feats.size());
  }

  @IsTest
  static void testGetDissolvedShapeGeometryMissingIds() {
    String responseJson = PSM_MapController.getDissolvedShapeGeometry(null);
    Map<String, Object> payload = (Map<String, Object>) JSON.deserializeUntyped(responseJson);
    System.assertEquals(false, payload.get('success'), responseJson);
  }

  @IsTest
  static void testGetDissolvedShapeGeometryHandlesHttpError() {
    Test.setMock(HttpCalloutMock.class, new DissolveHttpErrorMock());
    String responseJson = PSM_MapController.getDissolvedShapeGeometry('shape-1');
    Map<String, Object> payload = (Map<String, Object>) JSON.deserializeUntyped(responseJson);
    System.assertEquals(false, payload.get('success'), responseJson);
    System.assert(String.valueOf(payload.get('error')).contains('HTTP'));
  }

  @IsTest
  static void testGetDissolvedShapeGeometryBatchLoadsFeatures() {
    List<Object> specs = new List<Object>{
      new Map<String, Object>{
        'shapeRecordId' => 'a01shape1',
        'name' => 'Territory One',
        'color' => '#00FF00',
        'childIds' => new List<Object>{ 'child-1a', 'child-1b' }
      },
      new Map<String, Object>{
        'shapeRecordId' => 'a01shape2',
        'name' => 'Territory Two',
        'color' => '#0000FF',
        'childIds' => new List<Object>{ 'child-2a' }
      }
    };

    Test.setMock(HttpCalloutMock.class, new DissolveMock());
    Test.startTest();
    String responseJson = PSM_MapController.getDissolvedShapeGeometryBatch(JSON.serialize(specs));
    Test.stopTest();

    Map<String, Object> payload = (Map<String, Object>) JSON.deserializeUntyped(responseJson);
    System.assertEquals(true, payload.get('success'), responseJson);
    System.assertEquals(2, payload.get('requestedCount'));
    System.assertEquals(2, payload.get('loadedCount'));
    List<Object> features = (List<Object>) payload.get('features');
    System.assertEquals(2, features.size());

    Map<String, Object> feature0 = (Map<String, Object>) features[0];
    Map<String, Object> props0 = (Map<String, Object>) feature0.get('properties');
    System.assertEquals('Territory One', props0.get('name'));
    System.assertEquals('#00FF00', props0.get('color'));
    System.assertNotEquals(null, props0.get('centroidLat'));
    System.assertNotEquals(null, props0.get('centroidLng'));
  }

  @IsTest
  static void testGetDissolvedShapeGeometryBatchRejectsInvalidPayload() {
    String responseJson = PSM_MapController.getDissolvedShapeGeometryBatch('{"oops":true}');
    Map<String, Object> payload = (Map<String, Object>) JSON.deserializeUntyped(responseJson);
    System.assertEquals(false, payload.get('success'), responseJson);
  }

  @IsTest
  static void testGetDissolvedShapeGeometryBatchMissingPayload() {
    String responseJson = PSM_MapController.getDissolvedShapeGeometryBatch(null);
    Map<String, Object> payload = (Map<String, Object>) JSON.deserializeUntyped(responseJson);
    System.assertEquals(false, payload.get('success'), responseJson);
  }

  @IsTest
  static void testGetDissolvedShapeGeometryBatchInvalidChildIdsShape() {
    List<Object> specs = new List<Object>{
      new Map<String, Object>{
        'shapeRecordId' => 'a01shape1',
        'name' => 'Bad ChildIds Type',
        'childIds' => 'not-an-array'
      }
    };
    String responseJson = PSM_MapController.getDissolvedShapeGeometryBatch(JSON.serialize(specs));
    Map<String, Object> payload = (Map<String, Object>) JSON.deserializeUntyped(responseJson);
    System.assertEquals(true, payload.get('success'), responseJson);
    System.assertEquals(1, payload.get('requestedCount'));
    System.assertEquals(0, payload.get('loadedCount'));
  }

  @IsTest
  static void testGetDissolvedShapeGeometryBatchCapturesCalloutError() {
    List<Object> specs = new List<Object>{
      new Map<String, Object>{
        'shapeRecordId' => 'a01shape1',
        'name' => 'Error Territory',
        'childIds' => new List<Object>{ 'child-1' }
      }
    };
    Test.setMock(HttpCalloutMock.class, new DissolveHttpErrorMock());
    String responseJson = PSM_MapController.getDissolvedShapeGeometryBatch(JSON.serialize(specs));
    Map<String, Object> payload = (Map<String, Object>) JSON.deserializeUntyped(responseJson);
    System.assertEquals(true, payload.get('success'), responseJson);
    System.assertEquals(1, payload.get('requestedCount'));
    System.assertEquals(0, payload.get('loadedCount'));
    System.assertEquals(1, payload.get('errorCount'));
  }
}
