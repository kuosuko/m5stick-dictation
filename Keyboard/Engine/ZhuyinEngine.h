#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface ZhuyinCandidate : NSObject
@property (nonatomic, readonly) NSString *reading;
@property (nonatomic, readonly) NSString *value;
/// The rest of the walked sentence; choosing it accepts everything left.
@property (nonatomic, readonly) BOOL isWholeRest;
@end

/// One walked node: the characters and the syllable it starts at.
@interface ZhuyinSegment : NSObject
@property (nonatomic, readonly) NSString *text;
@property (nonatomic, readonly) NSUInteger start;
@end

/// Thin Objective-C++ wrapper over McBopomofo's engine: Bopomofo reading
/// buffer → ReadingGrid walk (sentence-level selection) → user override model.
/// Keys are McBopomofo "standard layout" ASCII keys ('1' = ㄅ, '3' = ˇ, …).
@interface ZhuyinEngine : NSObject

/// `userDirectory` holds user-phrases.txt, excluded-phrases.txt and the
/// learned-overrides journal; pass nil to keep learning in memory only.
- (nullable instancetype)initWithDataPath:(NSString *)dataPath
                    associatedPhrasesPath:(nullable NSString *)associatedPhrasesPath
                        abbreviationsPath:(nullable NSString *)abbreviationsPath
                            userDirectory:(nullable NSString *)userDirectory;

/// Returns NO when the key is not a Bopomofo key.
- (BOOL)handleKey:(char)key;
/// First tone. Returns NO when there is no reading to compose.
- (BOOL)handleSpace;
/// Returns NO when there was nothing left to delete inside the composition.
- (BOOL)backspace;

@property (nonatomic, readonly) BOOL isComposing;
/// Walked sentence followed by the reading still being typed.
@property (nonatomic, readonly) NSString *composingText;
/// What the text field shows while composing, like the system Zhuyin keyboard:
/// segments already chosen (before `syllable`) as characters, the rest as
/// Bopomofo, e.g. 「你ㄏㄠ」. The conversion itself lives in the candidate bar.
- (NSString *)markedTextConvertingBefore:(NSUInteger)syllable;
/// Just the Bopomofo still being typed, e.g. "ㄋㄧ".
@property (nonatomic, readonly) NSString *readingText;
/// Number of syllables already in the grid.
@property (nonatomic, readonly) NSUInteger syllableCount;

/// Syllable where the segment being chosen starts. Any segment can be
/// focused, so one wrong character in the middle is fixed in place.
/// Typing a new syllable resets it to the start of the sentence.
@property (nonatomic, readonly) NSUInteger focusIndex;
/// UTF-16 range, inside `composingText`, of the segment being chosen.
@property (nonatomic, readonly) NSRange focusRange;
/// The walked sentence split the way the engine segmented it.
@property (nonatomic, readonly) NSArray<ZhuyinSegment *> *segments;

/// The rest of the sentence from the focus first, then phrases starting at
/// the focus, longest first, deduplicated.
- (NSArray<ZhuyinCandidate *> *)candidates;
/// Applies the choice and moves the focus past it. Returns YES when the choice
/// covers the rest of the sentence, meaning it is ready to send.
- (BOOL)selectCandidate:(ZhuyinCandidate *)candidate;
- (void)focusSegmentAt:(NSUInteger)start;
- (BOOL)moveFocusBackward;
- (BOOL)moveFocusForward;
/// Phrases that usually follow what was just sent (聯想詞). Each candidate's
/// value is only the part to add, e.g. 「來」 after 「你」.
- (NSArray<ZhuyinCandidate *> *)associatedPhrases;
/// Records that an associated phrase was typed, so the next suggestions follow it.
- (void)acceptAssociatedPhrase:(ZhuyinCandidate *)candidate;
- (void)forgetAssociation;

/// Returns the walked text and clears everything.
- (NSString *)commit;
- (void)clear;

@end

NS_ASSUME_NONNULL_END
