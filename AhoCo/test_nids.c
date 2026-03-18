#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <assert.h>
#include "ac.h"
#include "gpu_ac.h"

// Utilitaire pour créer l'automate avec tous les patterns de test
AC_Machine* setup_test_machine() {
    AC_Machine *m = ac_create();
    // Patterns de base
    ac_add_pattern(m, "MALWARE", 1);
    ac_add_pattern(m, "EVIL", 2);
    ac_add_pattern(m, "ATTACK", 3);
    ac_add_pattern(m, "HELL", 4);
    ac_add_pattern(m, "HELLO", 5); 
    // Patterns pour tests avancés
    ac_add_pattern(m, "ABC", 10);
    ac_add_pattern(m, "BCD", 11);
    ac_add_pattern(m, "CDE", 12);
    ac_add_pattern(m, "AAAAA", 13);
    ac_add_pattern(m, "A", 14);
    ac_add_pattern(m, "\xff\xfe\xfd", 15);
    ac_finalize(m);
    return m;
}

// Helper pour tester une chaîne comme si c'était un seul paquet
long run_gpu_test_single_packet(AC_Machine *m, const char *data) {
    long data_len = strlen(data);
    long offset = 0;
    int length = (int)data_len;
    long matches = 0;
    run_gpu_packet_benchmark(m, data, &offset, &length, 1, 1, &matches);
    return matches;
}

// Helper pour les tests multi-paquets
long run_gpu_test_custom(AC_Machine *m, const char *data, long *offsets, int *lengths, int num_packets) {
    long matches = 0;
    run_gpu_packet_benchmark(m, data, offsets, lengths, num_packets, 1, &matches);
    return matches;
}

void test_identity() {
    printf("[TEST] Identity (CPU vs GPU)... ");
    AC_Machine *m = setup_test_machine();
    const char *data = "INIT_PAYLOAD_MALWARE_EVIL_HELLO_END";
    long cpu_matches = ac_search_benchmark(m, data, strlen(data));
    long gpu_matches = run_gpu_test_single_packet(m, data);
    if (cpu_matches != gpu_matches) { printf("FAILED! CPU: %ld, GPU: %ld\n", cpu_matches, gpu_matches); exit(1); }
    printf("PASSED (%ld matches)\n", cpu_matches);
    ac_free(m);
}

void test_overlap() {
    printf("[TEST] Overlapping Patterns (HELL/HELLO)... ");
    AC_Machine *m = setup_test_machine();
    const char *data = "HELLO"; 
    long gpu_matches = run_gpu_test_single_packet(m, data);
    if (gpu_matches != 2) { printf("FAILED! Expected 2, got %ld\n", gpu_matches); exit(1); }
    printf("PASSED\n");
    ac_free(m);
}

void test_overlapping_chain() {
    printf("[TEST] Overlapping Chain (ABCDE)... ");
    AC_Machine *m = setup_test_machine();
    const char *data = "ABCDE"; // A, ABC, BCD, CDE
    long offset = 0; int length = 5;
    long res = run_gpu_test_custom(m, data, &offset, &length, 1);
    if (res != 4) { printf("FAILED! Got %ld\n", res); exit(1); }
    printf("PASSED\n");
    ac_free(m);
}

void test_repetitive_patterns() {
    printf("[TEST] Repetitive Patterns (AAAAAA)... ");
    AC_Machine *m = setup_test_machine();
    const char *data = "AAAAAA"; 
    long offset = 0; int length = 6;
    long res = run_gpu_test_custom(m, data, &offset, &length, 1);
    // 2x "AAAAA" + 6x "A" = 8 matches
    if (res != 8) { printf("FAILED! Got %ld\n", res); exit(1); }
    printf("PASSED\n");
    ac_free(m);
}

void test_binary_data() {
    printf("[TEST] Binary/Non-ASCII Data... ");
    AC_Machine *m = setup_test_machine();
    const char data[] = {0xff, 0xfe, 0xfd, 0x00, 0x41, 0x42, 0x43}; 
    long offset = 0; int length = 7;
    long res = run_gpu_test_custom(m, data, &offset, &length, 1);
    // Pattern binaire + ABC
    if (res != 3) { printf("FAILED! Got %ld\n", res); exit(1); }
    printf("PASSED\n");
    ac_free(m);
}

void test_empty_and_small_packets() {
    printf("[TEST] Empty and Tiny Packets... ");
    AC_Machine *m = setup_test_machine();
    const char *data = "ABC"; 
    long offsets[3] = {0, 0, 0};
    int lengths[3] = {0, 1, 3}; 
    long res = run_gpu_test_custom(m, data, offsets, lengths, 3);
    // Pkt 1(0), Pkt 2(1 match "A"), Pkt 3(2 matches "A","ABC") = 3
    if (res != 3) { printf("FAILED! Got %ld\n", res); exit(1); }
    printf("PASSED\n");
    ac_free(m);
}

void test_offset_jump() {
    printf("[TEST] Offset Jump (Gaps)... ");
    AC_Machine *m = setup_test_machine();
    const char *data = "ZZZABCZZZABC"; 
    long offsets[2] = {3, 9};
    int lengths[2] = {3, 3};
    long res = run_gpu_test_custom(m, data, offsets, lengths, 2);
    // Chaque paquet "ABC" match "A" et "ABC" = 2*2 = 4
    if (res != 4) { printf("FAILED! Got %ld\n", res); exit(1); }
    printf("PASSED\n");
    ac_free(m);
}

int main() {
    printf("--- Starting ENHANCED NIDS Unit Tests ---\n");
    test_identity();
    test_overlap();
    test_overlapping_chain();
    test_repetitive_patterns();
    test_binary_data();
    test_empty_and_small_packets();
    test_offset_jump();
    printf("--- All Tests Completed Successfully ---\n");
    return 0;
}