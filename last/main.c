#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <pcap.h>
#include "payload.h"

#define DEFAULT_PCAP "Pcap/MixFile.pcap"


int main(int argc, char const *argv[])
{   
    const char *pcap_file = DEFAULT_PCAP;
    if (argc > 1){
        pcap_file = argv[1];
    }

    PcapDataStore * pcapData = load_pcap_to_memory(pcap_file);
    if (!pcapData){
        return EXIT_FAILURE;
    }

    printf("Loaded %u packets \n",pcapData->packet_count);
    printf("Memory used : %.2f \n mb", pcapData->total_bytes / 1024.0 / 1024.0);

    return 0;
}
