// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'providers.dart';

// **************************************************************************
// RiverpodGenerator
// **************************************************************************

// GENERATED CODE - DO NOT MODIFY BY HAND
// ignore_for_file: type=lint, type=warning

@ProviderFor(greeting)
final greetingProvider = GreetingFamily._();

final class GreetingProvider extends $FunctionalProvider<String, String, String>
    with $Provider<String> {
  GreetingProvider._({
    required GreetingFamily super.from,
    required String super.argument,
  }) : super(
         retry: null,
         name: r'greetingProvider',
         isAutoDispose: true,
         dependencies: null,
         $allTransitiveDependencies: null,
       );

  @override
  String debugGetCreateSourceHash() => _$greetingHash();

  @override
  String toString() {
    return r'greetingProvider'
        ''
        '($argument)';
  }

  @$internal
  @override
  $ProviderElement<String> $createElement($ProviderPointer pointer) =>
      $ProviderElement(pointer);

  @override
  String create(Ref ref) {
    final argument = this.argument as String;
    return greeting(ref, name: argument);
  }

  /// {@macro riverpod.override_with_value}
  Override overrideWithValue(String value) {
    return $ProviderOverride(
      origin: this,
      providerOverride: $SyncValueProvider<String>(value),
    );
  }

  @override
  bool operator ==(Object other) {
    return other is GreetingProvider && other.argument == argument;
  }

  @override
  int get hashCode {
    return argument.hashCode;
  }
}

String _$greetingHash() => r'99aabe7581c21332cd0a58a6344e70de99eb7014';

final class GreetingFamily extends $Family
    with $FunctionalFamilyOverride<String, String> {
  GreetingFamily._()
    : super(
        retry: null,
        name: r'greetingProvider',
        dependencies: null,
        $allTransitiveDependencies: null,
        isAutoDispose: true,
      );

  GreetingProvider call({required String name}) =>
      GreetingProvider._(argument: name, from: this);

  @override
  String toString() => r'greetingProvider';
}

@ProviderFor(answer)
final answerProvider = AnswerProvider._();

final class AnswerProvider
    extends $FunctionalProvider<AsyncValue<int>, int, FutureOr<int>>
    with $FutureModifier<int>, $FutureProvider<int> {
  AnswerProvider._()
    : super(
        from: null,
        argument: null,
        retry: null,
        name: r'answerProvider',
        isAutoDispose: false,
        dependencies: null,
        $allTransitiveDependencies: null,
      );

  @override
  String debugGetCreateSourceHash() => _$answerHash();

  @$internal
  @override
  $FutureProviderElement<int> $createElement($ProviderPointer pointer) =>
      $FutureProviderElement(pointer);

  @override
  FutureOr<int> create(Ref ref) {
    return answer(ref);
  }
}

String _$answerHash() => r'd77f78b35ed19652cf0a8e90d2c63a7a8ff38312';

@ProviderFor(Counter)
final counterProvider = CounterFamily._();

final class CounterProvider extends $NotifierProvider<Counter, int> {
  CounterProvider._({
    required CounterFamily super.from,
    required int super.argument,
  }) : super(
         retry: null,
         name: r'counterProvider',
         isAutoDispose: true,
         dependencies: null,
         $allTransitiveDependencies: null,
       );

  @override
  String debugGetCreateSourceHash() => _$counterHash();

  @override
  String toString() {
    return r'counterProvider'
        ''
        '($argument)';
  }

  @$internal
  @override
  Counter create() => Counter();

  /// {@macro riverpod.override_with_value}
  Override overrideWithValue(int value) {
    return $ProviderOverride(
      origin: this,
      providerOverride: $SyncValueProvider<int>(value),
    );
  }

  @override
  bool operator ==(Object other) {
    return other is CounterProvider && other.argument == argument;
  }

  @override
  int get hashCode {
    return argument.hashCode;
  }
}

String _$counterHash() => r'2325635dd2cf7951c010cbcd1713bfaacc613930';

final class CounterFamily extends $Family
    with $ClassFamilyOverride<Counter, int, int, int, int> {
  CounterFamily._()
    : super(
        retry: null,
        name: r'counterProvider',
        dependencies: null,
        $allTransitiveDependencies: null,
        isAutoDispose: true,
      );

  CounterProvider call(int start) =>
      CounterProvider._(argument: start, from: this);

  @override
  String toString() => r'counterProvider';
}

abstract class _$Counter extends $Notifier<int> {
  late final _$args = ref.$arg as int;
  int get start => _$args;

  int build(int start);
  @$mustCallSuper
  @override
  WhenComplete runBuild() {
    final ref = this.ref as $Ref<int, int>;
    final element =
        ref.element
            as $ClassProviderElement<
              AnyNotifier<int, int>,
              int,
              Object?,
              Object?
            >;
    return element.handleCreate(ref, () => build(_$args));
  }
}

@ProviderFor(feed)
final feedProvider = FeedProvider._();

final class FeedProvider
    extends
        $FunctionalProvider<
          AsyncValue<List<String>>,
          List<String>,
          Stream<List<String>>
        >
    with $FutureModifier<List<String>>, $StreamProvider<List<String>> {
  FeedProvider._()
    : super(
        from: null,
        argument: null,
        retry: null,
        name: r'feedProvider',
        isAutoDispose: true,
        dependencies: null,
        $allTransitiveDependencies: null,
      );

  @override
  String debugGetCreateSourceHash() => _$feedHash();

  @$internal
  @override
  $StreamProviderElement<List<String>> $createElement(
    $ProviderPointer pointer,
  ) => $StreamProviderElement(pointer);

  @override
  Stream<List<String>> create(Ref ref) {
    return feed(ref);
  }
}

String _$feedHash() => r'88fdf5c3b0d7de33c84ce577c2d692d5b8b3eed4';
