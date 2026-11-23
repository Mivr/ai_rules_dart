import 'package:dio/dio.dart';
import 'package:json_annotation/json_annotation.dart';
import 'package:retrofit/retrofit.dart';

part 'api.g.dart';

@JsonSerializable()
class Task {
  Task({required this.id, required this.name, this.avatar});

  factory Task.fromJson(Map<String, dynamic> json) => _$TaskFromJson(json);

  final String id;
  final String name;
  final String? avatar;

  Map<String, dynamic> toJson() => _$TaskToJson(this);
}

@RestApi(baseUrl: 'https://example.invalid/v1/')
abstract class TaskClient {
  factory TaskClient(Dio dio, {String? baseUrl}) = _TaskClient;

  @GET('/tasks')
  Future<List<Task>> getTasks({@Query('limit') int limit = 10});

  @GET('/tasks/{id}')
  Future<Task> getTask(@Path('id') String id);

  @POST('/tasks')
  Future<Task> createTask(@Body() Task task);

  @DELETE('/tasks/{id}')
  Future<HttpResponse<void>> deleteTask(@Path() String id);

  @MultiPart()
  @POST('/upload')
  Future<void> upload(@Part(name: 'file') List<int> bytes);
}
