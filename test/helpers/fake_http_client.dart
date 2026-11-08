import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// A request the fake received.
class FakeHttpRequest {
  final String method;
  final Uri uri;
  final Map<String, String> headers;
  final String body;

  FakeHttpRequest(this.method, this.uri, this.headers, this.body);

  /// The JSON body of a POST.
  Object? get json => body.isEmpty ? null : jsonDecode(body);
}

/// An answer of the fake.
class FakeHttpResponse {
  final int statusCode;
  final String body;
  final Map<String, String> headers;

  const FakeHttpResponse(this.statusCode, this.body, {this.headers = const {}});

  FakeHttpResponse.json(Object? json, {this.statusCode = 200})
    : body = jsonEncode(json),
      headers = const {};
}

/// An [HttpClient] that answers from [handler] without touching the
/// network. Throwing in [handler] fails the request like a network error.
class FakeHttpClient implements HttpClient {
  FakeHttpClient(this.handler);

  FutureOr<FakeHttpResponse> Function(FakeHttpRequest request) handler;
  final requests = <FakeHttpRequest>[];
  bool closed = false;

  @override
  Duration? connectionTimeout;

  @override
  Future<HttpClientRequest> getUrl(Uri url) async =>
      _FakeClientRequest(this, 'GET', url);

  @override
  Future<HttpClientRequest> postUrl(Uri url) async =>
      _FakeClientRequest(this, 'POST', url);

  @override
  void close({bool force = false}) => closed = true;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeHeaders implements HttpHeaders {
  final values = <String, String>{};

  @override
  void set(String name, Object value, {bool preserveHeaderCase = false}) =>
      values[name.toLowerCase()] = '$value';

  @override
  void add(String name, Object value, {bool preserveHeaderCase = false}) =>
      values[name.toLowerCase()] = '$value';

  @override
  String? value(String name) => values[name.toLowerCase()];

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeClientRequest implements HttpClientRequest {
  _FakeClientRequest(this._client, this.method, this.uri);

  final FakeHttpClient _client;
  @override
  final String method;
  @override
  final Uri uri;
  final _body = <int>[];

  @override
  final HttpHeaders headers = _FakeHeaders();

  @override
  void add(List<int> data) => _body.addAll(data);

  @override
  void write(Object? object) => _body.addAll(utf8.encode('$object'));

  @override
  Future<HttpClientResponse> close() async {
    final request = FakeHttpRequest(
      method,
      uri,
      Map.of((headers as _FakeHeaders).values),
      utf8.decode(_body),
    );
    _client.requests.add(request);
    final response = await _client.handler(request);
    return _FakeClientResponse(response);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeClientResponse extends Stream<List<int>>
    implements HttpClientResponse {
  _FakeClientResponse(this._response) {
    for (final entry in _response.headers.entries) {
      headers.set(entry.key, entry.value);
    }
  }

  final FakeHttpResponse _response;

  @override
  final HttpHeaders headers = _FakeHeaders();

  @override
  int get statusCode => _response.statusCode;

  @override
  StreamSubscription<List<int>> listen(
    void Function(List<int> event)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) => Stream<List<int>>.value(utf8.encode(_response.body)).listen(
    onData,
    onError: onError,
    onDone: onDone,
    cancelOnError: cancelOnError,
  );

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
