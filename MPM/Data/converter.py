from scapy.all import rdpcap, TCP, UDP, Raw
import sys

def pcap_to_payload(pcap_file, output_file):
    print(f"Reading {pcap_file} ... (This may take a while)")
    
    # Read packets (Warning: rdpcap loads the whole file into RAM)
    # For very large files (>500MB), PcapReader (streaming) should be used instead.
    try:
        packets = rdpcap(pcap_file)
    except MemoryError:
        print("Error: The PCAP file is too large for your RAM. Try a smaller file.")
        return
    except FileNotFoundError:
        print(f"Error: File '{pcap_file}' not found.")
        return
    
    with open(output_file, "wb") as f:
        count = 0
        total_bytes = 0
        
        for pkt in packets:
            payload = b""
            
            # Check for content (Raw layer) within the packet
            # This extracts data from TCP/UDP packets (HTTP bodies, etc.)
            if pkt.haslayer(Raw):
                payload = pkt[Raw].load
            
            # Write payload to the binary file
            if payload:
                f.write(payload)
                # We simply append payloads back-to-back. 
                # For pure Aho-Corasick benchmarking, this is perfectly fine.
                total_bytes += len(payload)
                count += 1
                
    print(f"-" * 30)
    print(f"Extraction complete!")
    print(f"Packets with payload  : {count}")
    print(f"Total size generated  : {total_bytes / (1024*1024):.2f} MB")
    print(f"Output file           : {output_file}")
    print(f"-" * 30)

if __name__ == "__main__":
    if len(sys.argv) < 3:
        print("Usage: python pcap_to_bin.py <input.pcap> <output.bin>")
    else:
        pcap_to_payload(sys.argv[1], sys.argv[2])