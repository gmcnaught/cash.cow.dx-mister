#ifndef CASHCOW_HOOK_H
#define CASHCOW_HOOK_H

#ifdef __cplusplus
extern "C" {
#endif

/* Called from scheduler_co_poll() right after scheduler_wait_fpga_ready()
 * returns (inserted by tools/mister-wrapper/build-hps.sh). Spawns launch.sh
 * once, then only reaps it. */
void cashcow_hook_poll(void);

#ifdef __cplusplus
}
#endif

#endif /* CASHCOW_HOOK_H */
