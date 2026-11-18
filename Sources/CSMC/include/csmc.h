#ifndef CSMC_H
#define CSMC_H
#include <stdint.h>

// Opens the AppleSMC user client. Returns 0 on success.
int smc_open(void);
// Reads a key (4-char code packed big-endian). Fills out (>=32 bytes), size and type. Returns 0 on success.
int smc_read(uint32_t key, uint8_t *out, uint32_t *size, uint32_t *type);
// Returns the key code at the given index (0 on failure).
uint32_t smc_key_at(uint32_t index);

// Writes a key (size must match the key's size). Returns 0 on success, negative on local failure,
// positive = the SMC's own result code (e.g. not permitted).
int smc_write(uint32_t key, const uint8_t *bytes, uint32_t size);

#endif
