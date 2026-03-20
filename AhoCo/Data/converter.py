import dpkt
import sys
import os
import time
from tqdm import tqdm

def extract_payloads(input_pcap, output_bin):
    """
    Extracts TCP/UDP payloads from a PCAP file and saves them into a binary file.
    It removes header to only keep the fres payload that will be used for the GPU.
    """
    
    if not os.path.exists(input_pcap):
        print(f"Error: File '{input_pcap}' not found.")
        return

    print(f"Starting extraction: {input_pcap}")
    start_time = time.time()
    
    packet_count = 0
    total_bytes = 0

    with open(input_pcap, 'rb') as f_in, open(output_bin, 'wb') as f_out:
        try :
            reader = dpkt.pcap.Reader(f_in)
        except Exception as e:
            print("Add a Pcap file as input")
            return
        for buf in tqdm(reader, desc="Processing packets", unit="pkts"): #tqdm is for progress bar
            try:
                eth = dpkt.ethernet.Ethernet(buf)
                if not isinstance(eth.data, (dpkt.ip.IP, dpkt.ip6.IP6)):
                    continue
                ip = eth.data
                if isinstance(ip.data, (dpkt.tcp.TCP, dpkt.udp.UDP)):
                    payload = ip.data.data
                    print(payload)
                    if payload:
                        f_out.write(payload)
                        total_bytes += len(payload)
                        packet_count += 1
                        
            except Exception:
                continue

    duration = time.time() - start_time
    size_mb = total_bytes / (1024 * 1024)
    
    print("\n" + "="*30)
    print("✅ EXTRACTION COMPLETE")
    print(f"Packets with payload: {packet_count:,}")
    print(f"Total payload size  : {size_mb:.2f} MB")
    print(f"Execution time      : {duration:.2f} seconds")
    print("="*30)

if __name__ == "__main__":
    if len(sys.argv) < 3 or len(sys.argv) > 3:
        print("Usage: python pcap_extractor.py <input.pcap> <output.bin>")
    else:
        extract_payloads(sys.argv[1], sys.argv[2])