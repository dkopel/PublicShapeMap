@IsTest
private class PSM_MapController_Test {
  private class FolderDirectMock implements HttpCalloutMock {
    public HTTPResponse respond(HTTPRequest req) {
      HttpResponse res = new HttpResponse();
      res.setStatusCode(200);
      String b = req.getBody();
      if (b != null && b.contains('"parentId"')) {
        res.setBody(
          '{"geoShapes":{"type":"FeatureCollection","features":[' +
            '{"type":"Feature","properties":{"id":"poly-1","name":"Territory","type":"Polygon"},' +
            '"geometry":{"type":"Polygon","coordinates":[[[-106.0,39.0],[-103.0,39.0],[-103.0,41.0],[-106.0,41.0],[-106.0,39.0]]]}}' +
            ']}}'
        );
      } else {
        res.setBody('{"geoShapes":{"type":"FeatureCollection","features":[]}}');
      }
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
  static void testGetVisibleShapesLoadsFolderDirectGeometry() {
    PSM_MapController.testOverrideFolderRootId = 'fld-root';
    Test.setMock(HttpCalloutMock.class, new FolderDirectMock());
    Test.startTest();
    String responseJson = PSM_MapController.getVisibleShapesForViewport(0, 0, 0, 0, 0);
    Test.stopTest();
    PSM_MapController.testOverrideFolderRootId = null;
    Map<String, Object> payload = (Map<String, Object>) JSON.deserializeUntyped(responseJson);
    System.assertEquals(true, payload.get('success'), responseJson);
    Map<String, Object> fc = (Map<String, Object>) payload.get('geoJson');
    List<Object> feats = (List<Object>) fc.get('features');
    System.assertEquals(1, feats.size());
    System.assertEquals(1, payload.get('shapeCount'));
    Map<String, Object> dbg = (Map<String, Object>) payload.get('debug');
    System.assertNotEquals(null, dbg);
    System.assertEquals('folder-direct', dbg.get('mode'));
  }
}
