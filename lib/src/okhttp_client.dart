import 'dart:isolate';
import 'dart:typed_data';

import 'package:async/async.dart';
import 'package:http/http.dart';
import 'package:jni/jni.dart';

import 'jni/jni_bindings.dart';

class OkhttpClient extends BaseClient {
  @override
  Future<StreamedResponse> send(BaseRequest request) async {
    final receivePort = ReceivePort();
    final events = StreamQueue<dynamic>(receivePort);

    await Isolate.spawn(_executeBackgroundHttpRequest, (
      url: request.url.toString(),
      method: request.method,
      headers: request.headers,
      body: await request.finalize().toBytes(),
      sendPort: receivePort.sendPort
    ));

    final statusCode = await events.next as int;
    final reasonPhrase = await events.next as String;
    final responseHeaders = await events.next as Map<String, String>;

    Stream<List<int>> responseBodyStream(Stream<dynamic> events) async* {
      try {
        await for (final event in events) {
          if (event is List<int>) {
            yield event;
          } else if (event is ClientException) {
            throw event;
          } else if (event == null) {
            return;
          }
        }
      } finally {
        receivePort.close();
      }
    }

    return StreamedResponse(responseBodyStream(events.rest), statusCode,
        contentLength: _contentLength(responseHeaders),
        request: request,
        headers: responseHeaders,
        reasonPhrase: reasonPhrase);
  }

  void _executeBackgroundHttpRequest(
      ({
        String url,
        String method,
        Map<String, String> headers,
        Uint8List body,
        SendPort sendPort
      }) args) {
    final client = OkHttpClient();
    final builder = Request_Builder();

    builder.url1(args.url.toString().toJString());

    args.headers.forEach(
        (key, value) => builder.addHeader(key.toJString(), value.toJString()));

    builder.method(
        args.method.toJString(), _initRequestBody(args.method, args.body));

    final response = client.newCall(builder.build()).execute();

    args.sendPort.send(response.code());
    args.sendPort.send(response.message().toDartString(releaseOriginal: true));
    args.sendPort.send(_responseHeaders(response.headers1()));

    const bufferSize = 4 * 1024;
    final bytesArray = JArray(jbyte.type, bufferSize);
    final responseBodyStream = response.body().source();

    try {
      while (true) {
        final bytesCount = responseBodyStream.read(bytesArray);
        if (bytesCount == -1) break;

        args.sendPort.send(bytesArray.toUint8List(length: bytesCount));
      }
    } catch (e) {
      args.sendPort.send(ClientException(e.toString()));
    }

    args.sendPort.send(null);
  }

  int? _contentLength(Map<String, String> headers) {
    final contentLength = headers['content-length'];
    if (contentLength == null) return null;

    try {
      final parsedContentLength = int.parse(contentLength);
      if (parsedContentLength < 0) {
        throw ClientException(
            'Invalid content-length header [$contentLength].');
      }
      return parsedContentLength;
    } on FormatException {
      throw ClientException('Invalid content-length header [$contentLength].');
    }
  }

  Map<String, String> _responseHeaders(Headers responseHeaders) {
    final headers = <String, List<String>>{};

    for (var i = 0; i < responseHeaders.size(); i++) {
      final headerName = responseHeaders.name(i);
      final headerValue = responseHeaders.value(i);

      headers
          .putIfAbsent(
              headerName.toDartString(releaseOriginal: true).toLowerCase(),
              () => [])
          .add(headerValue.toDartString(releaseOriginal: true));
    }

    return headers.map((key, value) => MapEntry(key, value.join(',')));
  }

  bool _allowsRequestBody(String method) {
    return !(method == 'GET' || method == 'HEAD');
  }

  RequestBody _initRequestBody(String method, Uint8List body) {
    if (!_allowsRequestBody(method)) return RequestBody.fromRef(nullptr);

    return RequestBody.create2(MediaType.fromRef(nullptr), body.toJArray());
  }
}

extension on Uint8List {
  JArray<jbyte> toJArray() =>
      JArray(jbyte.type, length)..setRange(0, length, this);
}

extension on JArray<jbyte> {
  Uint8List toUint8List({int? length}) {
    length ??= this.length;
    final list = Uint8List(length);
    for (var i = 0; i < length; i++) {
      list[i] = this[i];
    }
    return list;
  }
}
