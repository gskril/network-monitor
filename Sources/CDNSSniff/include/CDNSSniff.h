#ifndef CDNSSNIFF_H
#define CDNSSNIFF_H

// Minimal libpcap wrapper exposing a blocking packet-read loop to Swift.
// Swift parses the link-layer payload itself; this shim only handles
// opening the device, installing a BPF filter, and reading frames.

typedef struct cdns_handle cdns_handle;

// Opens `iface` for capture with the given BPF `filter` (e.g. "udp port 53").
// Returns NULL on failure and writes a message into `errbuf`. A NULL return
// with an EACCES-style message means BPF access was denied (needs the helper).
cdns_handle *cdns_open(const char *iface, const char *filter, char *errbuf, int errbuf_len);

// Link-layer type of the capture (DLT_* constant), to interpret frames.
int cdns_datalink(cdns_handle *handle);

// Reads the next frame. Returns 1 with *data/*len set on success, 0 on
// timeout (call again), and -1 on a terminal error. Blocks up to the
// configured read timeout. The buffer is owned by pcap; copy before the
// next call.
int cdns_next(cdns_handle *handle, const unsigned char **data, unsigned int *len);

// Wakes a blocked cdns_next so the capture thread can exit.
void cdns_breakloop(cdns_handle *handle);

void cdns_close(cdns_handle *handle);

#endif
