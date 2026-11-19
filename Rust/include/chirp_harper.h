#ifndef CHIRP_HARPER_H
#define CHIRP_HARPER_H
#include <stdint.h>
typedef struct ChirpChecker ChirpChecker;
/// dialect: 0 American, 1 British. words: newline-separated words to accept (may be NULL).
ChirpChecker *chirp_checker_new(uint8_t dialect, const char *words);
void chirp_checker_free(ChirpChecker *checker);
/// Returns a JSON array of lints with UTF-16 offsets. Free with chirp_string_free.
char *chirp_checker_lint(ChirpChecker *checker, const char *text);
void chirp_string_free(char *string);
#endif
