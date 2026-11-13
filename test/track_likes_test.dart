import 'package:flutter_test/flutter_test.dart';
import 'package:xmly_flutter/models/xmly_models.dart';

void main() {
  test(
    'track likes accepts nonnegative integers without inventing unknown counts',
    () {
      for (final value in <Object?>[
        null,
        -1,
        0.5,
        0.0,
        double.nan,
        double.infinity,
        double.negativeInfinity,
        '0',
        true,
      ]) {
        final track = Track.fromApi({'trackId': '1', 'likes': value});
        expect(track.likes, isNull, reason: 'Invalid likes: $value');
      }

      expect(Track.fromApi({'trackId': '1', 'likes': 0}).likes, 0);
      expect(Track.fromApi({'trackId': '1', 'likes': 16}).likes, 16);
      expect(
        Track.fromApi({'trackId': '1', 'likeCount': 12, 'totalCount': 30})
            .likes,
        isNull,
      );
    },
  );
}
