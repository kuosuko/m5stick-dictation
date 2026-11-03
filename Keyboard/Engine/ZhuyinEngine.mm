#import "ZhuyinEngine.h"

#include <algorithm>
#include <fstream>
#include <unordered_map>
#include <memory>
#include <sstream>
#include <string>
#include <unordered_set>
#include <vector>

#include "Mandarin/Mandarin.h"
#include "McBopomofoLM.h"
#include "ParselessLM.h"
#include "UserOverrideModel.h"
#include "gramambular2/reading_grid.h"

using Formosa::Gramambular2::LanguageModel;
using Formosa::Gramambular2::ReadingGrid;
using Formosa::Mandarin::BopomofoSyllable;
using Formosa::Mandarin::BopomofoKeyboardLayout;
using Formosa::Mandarin::BopomofoReadingBuffer;

// Same values as McBopomofo's LanguageModelManager.mm.
static const size_t kOverrideCapacity = 500;
static const double kOverrideHalfLife = 5400.0;
// McBopomofo only learns from choices whose score is above this.
static const double kObserveScoreFloor = -8;
static const size_t kJournalMaxLines = 2000;
// Marks a syllable typed without a tone, e.g. "ㄐㄧㄣ?". Punctuation readings
// also contain '?', but they start with '_' and never reach the grid here.
static const char kTonelessMark = '?';
// Marks a syllable typed only as its initial (簡拼), e.g. "ㄏ*": any syllable
// starting with ㄏ, in any tone.
static const char kInitialMark = '*';
// Past this many readings to look up, a phrase fans out too far to be worth it.
static const size_t kMaxCombinations = 3000;

/// True for a value made of one Bopomofo letter or tone mark (U+3100–312F, U+02C7, U+02CA–02D9).
static bool IsBopomofoSymbol(const std::string& value) {
  NSString* string = @(value.c_str());
  if (string.length != 1) return false;
  unichar c = [string characterAtIndex:0];
  return (c >= 0x3100 && c <= 0x312F) || (c >= 0x31A0 && c <= 0x31BF) || c == 0x02C7 || (c >= 0x02CA && c <= 0x02D9);
}

/// Lets readings be loose, like the system Zhuyin keyboard:
/// - a toneless syllable ("ㄐㄧㄣ?") matches all five tones;
/// - an initial on its own ("ㄏ*") matches every syllable starting with it;
/// - a run of initials only ("ㄏ*-ㄏ*-ㄏ*") is looked up in the 簡拼 index.
/// The walk then picks whichever reading reads best in context.
class TonelessLanguageModel : public LanguageModel {
 public:
  TonelessLanguageModel(std::shared_ptr<LanguageModel> lm, std::shared_ptr<LanguageModel> abbreviations,
                        std::unordered_map<std::string, std::vector<std::string>> syllablesByInitial)
      : lm_(std::move(lm)), abbreviations_(std::move(abbreviations)), syllablesByInitial_(std::move(syllablesByInitial)) {}

  std::vector<Unigram> getUnigrams(const std::string& reading) override {
    std::vector<std::vector<std::string>> options;
    std::vector<std::string> initials;
    size_t loose = 0;
    size_t initialOnly = 0;
    size_t combinations = 1;
    size_t start = 0;
    while (true) {
      size_t end = reading.find('-', start);
      std::string syllable = reading.substr(start, end == std::string::npos ? std::string::npos : end - start);
      bool marked = !syllable.empty() && syllable.front() != '_';
      if (marked && syllable.back() == kInitialMark) {
        ++loose;
        ++initialOnly;
        std::string initial = syllable.substr(0, syllable.size() - 1);
        initials.push_back(initial);
        std::vector<std::string> expanded;
        auto found = syllablesByInitial_.find(initial);
        if (found != syllablesByInitial_.end()) {
          for (const auto& base : found->second) {
            for (const char* tone : {"", "ˊ", "ˇ", "ˋ", "˙"}) expanded.push_back(base + tone);
          }
        }
        options.push_back(std::move(expanded));
      } else if (marked && syllable.back() == kTonelessMark) {
        ++loose;
        std::string base = syllable.substr(0, syllable.size() - 1);
        options.push_back({base, base + "ˊ", base + "ˇ", base + "ˋ", base + "˙"});
      } else {
        options.push_back({syllable});
      }
      combinations *= std::max<size_t>(options.back().size(), 1);
      if (end == std::string::npos) break;
      start = end + 1;
    }
    if (loose == 0) return lm_->getUnigrams(reading);

    // Every syllable typed as just an initial: the 簡拼 index has the phrases.
    if (initialOnly == options.size() && options.size() > 1) {
      std::string key;
      for (size_t i = 0; i < initials.size(); ++i) key += (i > 0 ? "-" : "") + initials[i];
      return abbreviations_ ? abbreviations_->getUnigrams(key) : std::vector<Unigram>{};
    }
    if (initialOnly > 1 || combinations > kMaxCombinations) return {};

    std::vector<Unigram> merged;
    std::unordered_map<std::string, size_t> index;
    std::vector<size_t> pick(options.size(), 0);
    while (true) {
      std::string candidate;
      for (size_t i = 0; i < options.size(); ++i) {
        if (options[i].empty()) return {};
        if (i > 0) candidate += '-';
        candidate += options[i][pick[i]];
      }
      for (const auto& unigram : lm_->getUnigrams(candidate)) {
        // The data maps lone letters to themselves ("ㄐ ㄐ"); loose input would
        // otherwise leave a stray ㄐ in the sentence.
        if (IsBopomofoSymbol(unigram.value())) continue;
        auto found = index.find(unigram.value());
        if (found == index.end()) {
          index.emplace(unigram.value(), merged.size());
          merged.push_back(unigram);
        } else if (unigram.score() > merged[found->second].score()) {
          merged[found->second] = unigram;
        }
      }
      size_t digit = 0;
      while (digit < pick.size() && ++pick[digit] == options[digit].size()) pick[digit++] = 0;
      if (digit == pick.size()) break;
    }
    std::stable_sort(merged.begin(), merged.end(),
                     [](const Unigram& a, const Unigram& b) { return a.score() > b.score(); });
    return merged;
  }

  bool hasUnigrams(const std::string& reading) override {
    if (reading.find(kTonelessMark) == std::string::npos && reading.find(kInitialMark) == std::string::npos) {
      return lm_->hasUnigrams(reading);
    }
    return !getUnigrams(reading).empty();
  }

 private:
  std::shared_ptr<LanguageModel> lm_;
  std::shared_ptr<LanguageModel> abbreviations_;
  std::unordered_map<std::string, std::vector<std::string>> syllablesByInitial_;
};

/// Every start of a real syllable, without tone: ㄓ, ㄓㄨ, ㄓㄨㄤ, ㄧ, ㄧㄠ….
/// Typing past one of these into something no syllable starts with (ㄓ then ㄧ)
/// means the key begins the next character.
static std::unordered_set<std::string> SyllableStarts(McBopomofo::McBopomofoLM& lm) {
  std::unordered_set<std::string> starts;
  const auto* layout = BopomofoKeyboardLayout::StandardLayout();
  const std::string initials = std::string("1qaz2wsxedcrfv5tgbyhn") + '\0';
  const std::string medials = std::string("ujm") + '\0';
  const std::string finals = std::string("8ik,9ol.0p;/-") + '\0';
  for (char initial : initials) {
    for (char medial : medials) {
      for (char final : finals) {
        BopomofoReadingBuffer buffer(layout);
        for (char key : {initial, medial, final}) {
          if (key != '\0') buffer.combineKey(key);
        }
        std::string base = buffer.syllable().composedString();
        if (base.empty()) continue;
        bool known = false;
        for (const char* tone : {"", "ˊ", "ˇ", "ˋ", "˙"}) {
          if (lm.hasUnigrams(base + tone)) { known = true; break; }
        }
        // Each Bopomofo letter is 3 bytes of UTF-8.
        for (size_t length = 3; known && length <= base.size(); length += 3) starts.insert(base.substr(0, length));
      }
    }
  }
  return starts;
}

/// Every real syllable (without tone) grouped by its initial, e.g. ㄏ → ㄏㄚ, ㄏㄜ, ㄏㄠ….
/// Built once by composing all initial/medial/final combinations and keeping those the data knows.
static std::unordered_map<std::string, std::vector<std::string>> SyllablesByInitial(McBopomofo::McBopomofoLM& lm) {
  std::unordered_map<std::string, std::vector<std::string>> table;
  const auto* layout = BopomofoKeyboardLayout::StandardLayout();
  const std::string initials = "1qaz2wsxedcrfv5tgbyhn";
  const std::string medials = std::string("ujm") + '\0';
  const std::string finals = std::string("8ik,9ol.0p;/-") + '\0';
  for (char initial : initials) {
    std::string initialText;
    for (char medial : medials) {
      for (char final : finals) {
        BopomofoReadingBuffer buffer(layout);
        buffer.combineKey(initial);
        if (initialText.empty()) initialText = buffer.composedString();
        if (medial != '\0') buffer.combineKey(medial);
        if (final != '\0') buffer.combineKey(final);
        std::string base = buffer.syllable().composedString();
        bool known = false;
        for (const char* tone : {"", "ˊ", "ˇ", "ˋ", "˙"}) {
          if (lm.hasUnigrams(base + tone)) { known = true; break; }
        }
        auto& list = table[initialText];
        if (known && std::find(list.begin(), list.end(), base) == list.end()) list.push_back(base);
      }
    }
  }
  return table;
}

/// Upstream keeps learned overrides in memory only. A keyboard extension is
/// killed often, so every observation is appended to a journal and replayed
/// on launch. Relies on the local `virtual` patch, see Vendor/VENDOR.md.
class JournalingUserOverrideModel : public McBopomofo::UserOverrideModel {
 public:
  explicit JournalingUserOverrideModel(std::string path)
      : UserOverrideModel(kOverrideCapacity, kOverrideHalfLife), path_(std::move(path)) {}

  using UserOverrideModel::observe;

  void observe(const std::string& key, const std::string& candidate, double timestamp,
               bool forceHighScoreOverride) override {
    UserOverrideModel::observe(key, candidate, timestamp, forceHighScoreOverride);
    if (replaying_ || path_.empty()) return;
    std::ofstream out(path_, std::ios::app);
    out << key << '\t' << candidate << '\t' << timestamp << '\t' << (forceHighScoreOverride ? 1 : 0)
        << '\n';
  }

  void replay() {
    if (path_.empty()) return;
    std::ifstream in(path_);
    std::vector<std::string> lines;
    for (std::string line; std::getline(in, line);) {
      if (!line.empty()) lines.push_back(line);
    }
    in.close();
    if (lines.size() > kJournalMaxLines) {
      lines.erase(lines.begin(), lines.end() - kJournalMaxLines);
      std::ofstream out(path_, std::ios::trunc);
      for (const auto& line : lines) out << line << '\n';
    }
    replaying_ = true;
    for (const auto& line : lines) {
      std::istringstream fields(line);
      std::string key, candidate, timestamp, force;
      if (!std::getline(fields, key, '\t') || !std::getline(fields, candidate, '\t') ||
          !std::getline(fields, timestamp, '\t') || !std::getline(fields, force, '\t')) {
        continue;
      }
      observe(key, candidate, std::strtod(timestamp.c_str(), nullptr), force == "1");
    }
    replaying_ = false;
  }

 private:
  std::string path_;
  bool replaying_ = false;
};

@interface ZhuyinCandidate ()
- (instancetype)initWithReading:(const std::string &)reading value:(const std::string &)value;
- (instancetype)initWithWholeRest:(const std::string &)value;
- (const std::string &)rawReading;
- (const std::string &)rawValue;
@end

@implementation ZhuyinCandidate {
  std::string _reading;
  std::string _value;
  BOOL _isWholeRest;
}

- (instancetype)initWithWholeRest:(const std::string &)value {
  if ((self = [self initWithReading:"" value:value])) _isWholeRest = YES;
  return self;
}

- (BOOL)isWholeRest { return _isWholeRest; }

- (instancetype)initWithReading:(const std::string &)reading value:(const std::string &)value {
  if ((self = [super init])) {
    _reading = reading;
    _value = value;
  }
  return self;
}

- (NSString *)reading { return @(_reading.c_str()); }
- (NSString *)value { return @(_value.c_str()); }
- (const std::string &)rawReading { return _reading; }
- (const std::string &)rawValue { return _value; }

@end

@implementation ZhuyinSegment

- (instancetype)initWithText:(NSString *)text start:(NSUInteger)start {
  if ((self = [super init])) {
    _text = [text copy];
    _start = start;
  }
  return self;
}

@end

@implementation ZhuyinEngine {
  std::shared_ptr<McBopomofo::McBopomofoLM> _lm;
  std::shared_ptr<TonelessLanguageModel> _toneless;
  std::unique_ptr<ReadingGrid> _grid;
  std::unique_ptr<BopomofoReadingBuffer> _buffer;
  std::unordered_set<std::string> _syllableStarts;
  std::unique_ptr<JournalingUserOverrideModel> _overrides;
  ReadingGrid::WalkResult _walk;
  size_t _focus;
  /// The syllable still being typed is already in the grid as a toneless
  /// reading, so the sentence updates on every key.
  BOOL _live;
  /// The last word sent, which 聯想詞 continue from.
  std::string _lastSent;
}

- (nullable instancetype)initWithDataPath:(NSString *)dataPath
                    associatedPhrasesPath:(nullable NSString *)associatedPhrasesPath
                        abbreviationsPath:(nullable NSString *)abbreviationsPath
                            userDirectory:(nullable NSString *)userDirectory {
  if (!(self = [super init])) return nil;

  _lm = std::make_shared<McBopomofo::McBopomofoLM>();
  _lm->loadLanguageModel(dataPath.fileSystemRepresentation);
  if (!_lm->isDataModelLoaded()) return nil;
  if (associatedPhrasesPath != nil) _lm->loadAssociatedPhrasesV2(associatedPhrasesPath.fileSystemRepresentation);

  std::string journal;
  if (userDirectory != nil) {
    NSFileManager *files = NSFileManager.defaultManager;
    [files createDirectoryAtPath:userDirectory withIntermediateDirectories:YES attributes:nil error:nil];
    NSString *phrases = [userDirectory stringByAppendingPathComponent:@"user-phrases.txt"];
    NSString *excluded = [userDirectory stringByAppendingPathComponent:@"excluded-phrases.txt"];
    for (NSString *path in @[ phrases, excluded ]) {
      if (![files fileExistsAtPath:path]) [files createFileAtPath:path contents:[NSData data] attributes:nil];
    }
    _lm->loadUserPhrases(phrases.fileSystemRepresentation, excluded.fileSystemRepresentation);
    journal = [userDirectory stringByAppendingPathComponent:@"learned-overrides.tsv"].fileSystemRepresentation;
  }

  std::shared_ptr<McBopomofo::ParselessLM> abbreviations;
  if (abbreviationsPath != nil) {
    abbreviations = std::make_shared<McBopomofo::ParselessLM>();
    if (!abbreviations->open(abbreviationsPath.fileSystemRepresentation)) abbreviations.reset();
  }
  _toneless = std::make_shared<TonelessLanguageModel>(_lm, abbreviations, SyllablesByInitial(*_lm));
  _syllableStarts = SyllableStarts(*_lm);
  _grid = std::make_unique<ReadingGrid>(_toneless);
  _buffer = std::make_unique<BopomofoReadingBuffer>(BopomofoKeyboardLayout::StandardLayout());
  _overrides = std::make_unique<JournalingUserOverrideModel>(journal);
  _overrides->replay();
  return self;
}

#pragma mark - Typing

- (BOOL)handleKey:(char)key {
  if (!_buffer->isValidKey(key)) return NO;
  auto components = _buffer->keyboardLayout()->keyToComponents(key);
  BopomofoSyllable::Component component = components.empty() ? 0 : components.front();

  if (component & BopomofoSyllable::ToneMarkerMask) {
    // A tone with nothing to attach to is dropped rather than left as a stray mark.
    if (_buffer->isEmpty()) return YES;
    _focus = 0;
    [self dropLive];
    _buffer->combineKey(key);
    std::string reading = _buffer->syllable().composedString();
    _buffer->clear();
    if (_lm->hasUnigrams(reading)) {
      _grid->insertReading(reading);
      [self applyLearnedOverride];
    }
    [self walk];
    return YES;
  }

  _focus = 0;
  // ㄐㄧㄣ then ㄊ: the ㄊ starts the next character instead of replacing ㄐ.
  if (!_buffer->isEmpty() && [self cannotExtendSyllable:component]) {
    // ㄓ that can't take the ㄧ was meant as a whole syllable (之), not as 簡拼 for 主.
    [self dropLive];
    [self placeLiveWhole:YES];
    [self finalizeLive];
  } else if (!_buffer->isEmpty() && [self startsNewSyllable:component]) {
    [self finalizeLive];
  }
  [self dropLive];
  _buffer->combineKey(key);
  [self placeLive];
  [self walk];
  return YES;
}

/// True when `component` cannot extend the syllable being typed: its slot is
/// taken, or it belongs before a slot that is already filled.
- (BOOL)startsNewSyllable:(BopomofoSyllable::Component)component {
  BopomofoSyllable syllable = _buffer->syllable();
  if (component & BopomofoSyllable::ConsonantMask) {
    return syllable.hasConsonant() || syllable.hasMiddleVowel() || syllable.hasVowel();
  }
  if (component & BopomofoSyllable::MiddleVowelMask) return syllable.hasMiddleVowel() || syllable.hasVowel();
  if (component & BopomofoSyllable::VowelMask) return syllable.hasVowel();
  return NO;
}

/// True when `component` would turn a real syllable start into something no
/// syllable starts with: ㄓ then ㄧ is 之一, not one character ㄓㄧ.
- (BOOL)cannotExtendSyllable:(BopomofoSyllable::Component)component {
  BopomofoSyllable syllable = _buffer->syllable();
  std::string current = syllable.composedString();
  std::string extended = (syllable + BopomofoSyllable(component)).composedString();
  return _syllableStarts.count(current) > 0 && _syllableStarts.count(extended) == 0;
}

- (BOOL)handleSpace {
  if (_buffer->isEmpty()) return NO;
  if (!_live) {
    // Not a word without a tone either; try it as an explicit first tone.
    std::string reading = _buffer->syllable().composedString();
    if (_lm->hasUnigrams(reading)) {
      _grid->insertReading(reading);
      _live = YES;
    }
  }
  [self finalizeLive];
  [self walk];
  return YES;
}

- (BOOL)backspace {
  if (!_buffer->isEmpty()) {
    [self dropLive];
    _buffer->backspace();
    [self placeLive];
    [self walk];
    return YES;
  }
  if (_grid->length() == 0) return NO;
  _grid->deleteReadingBeforeCursor();
  _focus = std::min(_focus, _grid->length());
  [self walk];
  return YES;
}

- (void)dropLive {
  if (!_live) return;
  _grid->deleteReadingBeforeCursor();
  _focus = std::min(_focus, _grid->length());
  _live = NO;
}

- (void)placeLive {
  [self placeLiveWhole:NO];
}

/// `whole`: take the syllable as typed even when it is only an initial,
/// instead of reading the initial as 簡拼.
- (void)placeLiveWhole:(BOOL)whole {
  if (_buffer->isEmpty()) return;
  // Only an initial so far: offer every syllable it could become (簡拼).
  BopomofoSyllable syllable = _buffer->syllable();
  bool initialOnly = !whole && syllable.hasConsonant() && !syllable.hasMiddleVowel() && !syllable.hasVowel();
  std::string reading = syllable.composedString() + (initialOnly ? kInitialMark : kTonelessMark);
  if (!_toneless->hasUnigrams(reading)) return;
  _grid->insertReading(reading);
  _live = YES;
}

/// Turns the syllable being typed into a settled one. A partial that never
/// matched anything (a lone ㄋ, say) is dropped.
- (void)finalizeLive {
  BOOL wasLive = _live;
  _live = NO;
  _buffer->clear();
  if (wasLive) {
    [self walk];
    [self applyLearnedOverride];
  }
}

- (void)applyLearnedOverride {
  [self walk];
  auto suggestion = _overrides->suggest(_walk, [self candidateCursor], [NSDate date].timeIntervalSince1970);
  if (suggestion.empty()) return;
  auto type = suggestion.forceHighScoreOverride
                  ? ReadingGrid::Node::OverrideType::kOverrideValueWithHighScore
                  : ReadingGrid::Node::OverrideType::kOverrideValueWithScoreFromTopUnigram;
  _grid->overrideCandidate([self candidateCursor], suggestion.candidate, type);
}

- (void)walk {
  _walk = _grid->walk();
}

/// The newest syllable, which is what the override model suggests for.
- (size_t)candidateCursor {
  size_t length = _grid->length();
  return length > 0 ? length - 1 : 0;
}

#pragma mark - State

- (BOOL)isComposing {
  return _grid->length() > 0 || !_buffer->isEmpty();
}

- (NSString *)composingText {
  std::string text;
  for (const auto &node : _walk.nodes) text += node->value();
  if (!_live) text += _buffer->composedString();
  return @(text.c_str());
}

- (NSString *)markedTextConvertingBefore:(NSUInteger)syllable {
  std::string text;
  size_t covered = 0;
  for (const auto &node : _walk.nodes) {
    if (covered + node->spanningLength() > syllable) break;
    covered += node->spanningLength();
    text += node->value();
  }
  const auto &readings = _grid->readings();
  for (size_t i = covered; i < readings.size(); ++i) {
    std::string reading = readings[i];
    if (!reading.empty() && (reading.back() == kTonelessMark || reading.back() == kInitialMark)) reading.pop_back();
    text += reading;
  }
  if (!_live) text += _buffer->composedString();
  return @(text.c_str());
}

/// Bopomofo that has not turned into a character yet; empty while the
/// syllable is live in the sentence.
- (NSString *)readingText {
  return _live ? @"" : @(_buffer->composedString().c_str());
}

- (NSUInteger)syllableCount {
  return _grid->length();
}

#pragma mark - Candidates

- (NSUInteger)focusIndex {
  return _focus;
}

- (NSArray<ZhuyinSegment *> *)segments {
  NSMutableArray<ZhuyinSegment *> *result = [NSMutableArray array];
  size_t covered = 0;
  for (const auto &node : _walk.nodes) {
    [result addObject:[[ZhuyinSegment alloc] initWithText:@(node->value().c_str()) start:covered]];
    covered += node->spanningLength();
  }
  return result;
}

- (void)focusSegmentAt:(NSUInteger)start {
  [self finalizeLive];
  [self walk];
  _focus = std::min<size_t>(start, _grid->length() > 0 ? _grid->length() - 1 : 0);
}

- (BOOL)moveFocusForward {
  [self finalizeLive];
  [self walk];
  size_t covered = 0;
  for (const auto &node : _walk.nodes) {
    covered += node->spanningLength();
    if (covered > _focus) break;
  }
  if (covered >= _grid->length()) return NO;
  _focus = covered;
  return YES;
}

/// UTF-16 length of the walked text for syllables [0, syllables).
- (NSUInteger)textLengthOfFirst:(size_t)syllables {
  std::string text;
  size_t covered = 0;
  for (const auto &node : _walk.nodes) {
    if (covered + node->spanningLength() > syllables) break;
    covered += node->spanningLength();
    text += node->value();
  }
  return @(text.c_str()).length;
}

- (NSRange)focusRange {
  NSUInteger location = [self textLengthOfFirst:_focus];
  size_t covered = 0;
  for (const auto &node : _walk.nodes) {
    if (covered == _focus) {
      NSUInteger length = [self textLengthOfFirst:_focus + node->spanningLength()] - location;
      return NSMakeRange(location, length);
    }
    covered += node->spanningLength();
  }
  return NSMakeRange(location, 0);
}

- (NSArray<ZhuyinCandidate *> *)candidates {
  size_t length = _grid->length();
  if (_focus >= length) return @[];
  NSMutableArray<ZhuyinCandidate *> *result = [NSMutableArray array];
  std::unordered_set<std::string> seen;

  if (length - _focus > 1) {
    std::string rest;
    size_t covered = 0;
    for (const auto &node : _walk.nodes) {
      if (covered >= _focus) rest += node->value();
      covered += node->spanningLength();
    }
    seen.insert(rest);
    [result addObject:[[ZhuyinCandidate alloc] initWithWholeRest:rest]];
  }

  const auto &readings = _grid->readings();
  size_t longest = std::min(length - _focus, ReadingGrid::kMaximumSpanLength);
  for (size_t span = longest; span >= 1; --span) {
    std::string reading;
    for (size_t i = _focus; i < _focus + span; ++i) {
      if (i > _focus) reading += _grid->readingSeparator();
      reading += readings[i];
    }
    for (const auto &unigram : _toneless->getUnigrams(reading)) {
      if (!seen.insert(unigram.value()).second) continue;
      [result addObject:[[ZhuyinCandidate alloc] initWithReading:reading value:unigram.value()]];
    }
  }
  return result;
}

- (BOOL)selectCandidate:(ZhuyinCandidate *)candidate {
  [self finalizeLive];
  [self walk];
  if (candidate.isWholeRest) {
    _focus = _grid->length();
    return YES;
  }
  // overrideCandidate mutates the nodes the current walk points at, so keep
  // a deep copy for the override model to compare against.
  ReadingGrid::WalkResult before = _walk.copyWithFixedNodes();
  ReadingGrid::Candidate choice(candidate.rawReading, candidate.rawValue);
  if (!_grid->overrideCandidate(_focus, choice)) return NO;
  [self walk];

  auto node = _walk.findNodeAt(_focus);
  if (node != _walk.nodes.cend() && *node != nullptr && (*node)->currentUnigram().score() > kObserveScoreFloor) {
    _overrides->observe(before, _walk, _focus, [NSDate date].timeIntervalSince1970);
  }
  size_t span = std::count(candidate.rawReading.begin(), candidate.rawReading.end(), '-') + 1;
  _focus = std::min(_focus + span, _grid->length());
  return _focus >= _grid->length();
}

- (BOOL)moveFocusBackward {
  [self finalizeLive];
  [self walk];
  if (_focus == 0) return NO;
  size_t covered = 0;
  for (const auto &node : _walk.nodes) {
    if (covered + node->spanningLength() >= _focus) break;
    covered += node->spanningLength();
  }
  _focus = covered;
  return YES;
}

- (NSString *)commit {
  [self finalizeLive];
  [self walk];
  std::string text;
  for (const auto &node : _walk.nodes) text += node->value();
  std::string last = _walk.nodes.empty() ? "" : _walk.nodes.back()->value();
  [self clear];
  _lastSent = last;
  return @(text.c_str());
}

#pragma mark - Associated phrases

/// Associated phrases continuing `prefix`, which the table keys by character
/// plus tone-exact reading. The walk may hold toneless readings, so the
/// word's best reading is looked up again.
- (std::vector<McBopomofo::AssociatedPhrasesV2::Phrase>)phrasesAfter:(const std::string &)prefix {
  std::vector<std::string> readings;
  std::string reading = _lm->getReading(prefix);
  if (!reading.empty()) readings = McBopomofo::AssociatedPhrasesV2::SplitReadings(reading);
  auto phrases = _lm->findAssociatedPhrasesV2(prefix, readings);
  if (phrases.empty() && !readings.empty()) phrases = _lm->findAssociatedPhrasesV2(prefix, {});
  return phrases;
}

- (NSArray<ZhuyinCandidate *> *)associatedPhrases {
  if (_lastSent.empty() || !_lm->isAssociatedPhrasesV2Loaded()) return @[];
  std::string prefix = _lastSent;
  auto phrases = [self phrasesAfter:prefix];
  if (phrases.empty()) {
    // Few multi-character words start a row (「天氣」 has none); fall back to the last character.
    NSString *word = @(_lastSent.c_str());
    if (word.length > 1) {
      NSRange last = [word rangeOfComposedCharacterSequenceAtIndex:word.length - 1];
      prefix = [word substringWithRange:last].UTF8String;
      phrases = [self phrasesAfter:prefix];
    }
  }

  NSMutableArray<ZhuyinCandidate *> *result = [NSMutableArray array];
  std::unordered_set<std::string> seen;
  for (const auto &phrase : phrases) {
    if (phrase.value.size() <= prefix.size() || phrase.value.compare(0, prefix.size(), prefix) != 0) continue;
    std::string rest = phrase.value.substr(prefix.size());
    if (!seen.insert(rest).second) continue;
    [result addObject:[[ZhuyinCandidate alloc] initWithReading:phrase.combinedReading() value:rest]];
  }
  return result;
}

- (void)acceptAssociatedPhrase:(ZhuyinCandidate *)candidate {
  _lastSent += candidate.rawValue;
}

- (void)forgetAssociation {
  _lastSent.clear();
}

- (void)clear {
  _buffer->clear();
  _grid->clear();
  _walk = ReadingGrid::WalkResult();
  _focus = 0;
  _live = NO;
}

@end
