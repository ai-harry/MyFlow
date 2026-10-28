#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Runs `block`, converting any Objective-C exception it raises into an
/// NSError. Swift cannot catch NSException — AVAudioEngine raises them (e.g.
/// installTap during a Bluetooth format switch) and they abort the process.
BOOL MFTryObjC(NS_NOESCAPE void (^block)(void), NSError * _Nullable * _Nullable error);

NS_ASSUME_NONNULL_END
