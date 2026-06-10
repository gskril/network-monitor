#include "CDNSSniff.h"
#include <pcap.h>
#include <string.h>
#include <stdlib.h>

struct cdns_handle {
    pcap_t *pcap;
};

cdns_handle *cdns_open(const char *iface, const char *filter, char *errbuf, int errbuf_len) {
    char pcap_err[PCAP_ERRBUF_SIZE];
    pcap_err[0] = '\0';

    pcap_t *pcap = pcap_create(iface, pcap_err);
    if (!pcap) {
        snprintf(errbuf, errbuf_len, "%s", pcap_err);
        return NULL;
    }

    // Enough for a full DNS-over-UDP answer; immediate mode avoids buffering
    // latency so mappings are learned right as the lookup completes.
    pcap_set_snaplen(pcap, 4096);
    pcap_set_promisc(pcap, 0);
    pcap_set_timeout(pcap, 250);
    pcap_set_immediate_mode(pcap, 1);

    int rc = pcap_activate(pcap);
    if (rc < 0) {
        snprintf(errbuf, errbuf_len, "%s", pcap_geterr(pcap));
        pcap_close(pcap);
        return NULL;
    }

    struct bpf_program program;
    if (pcap_compile(pcap, &program, filter, 1, PCAP_NETMASK_UNKNOWN) < 0) {
        snprintf(errbuf, errbuf_len, "filter compile: %s", pcap_geterr(pcap));
        pcap_close(pcap);
        return NULL;
    }
    if (pcap_setfilter(pcap, &program) < 0) {
        snprintf(errbuf, errbuf_len, "set filter: %s", pcap_geterr(pcap));
        pcap_freecode(&program);
        pcap_close(pcap);
        return NULL;
    }
    pcap_freecode(&program);

    cdns_handle *handle = calloc(1, sizeof(cdns_handle));
    if (!handle) {
        snprintf(errbuf, errbuf_len, "out of memory");
        pcap_close(pcap);
        return NULL;
    }
    handle->pcap = pcap;
    return handle;
}

int cdns_datalink(cdns_handle *handle) {
    return pcap_datalink(handle->pcap);
}

int cdns_next(cdns_handle *handle, const unsigned char **data, unsigned int *len) {
    struct pcap_pkthdr *header = NULL;
    const unsigned char *bytes = NULL;
    int rc = pcap_next_ex(handle->pcap, &header, &bytes);
    if (rc == 1) {
        *data = bytes;
        *len = header->caplen;
        return 1;
    }
    if (rc == 0) {
        return 0; // timeout
    }
    return -1; // PCAP_ERROR or break
}

void cdns_breakloop(cdns_handle *handle) {
    pcap_breakloop(handle->pcap);
}

void cdns_close(cdns_handle *handle) {
    if (!handle) return;
    if (handle->pcap) pcap_close(handle->pcap);
    free(handle);
}
