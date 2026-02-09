import re
import sys

def extract_suricata_patterns(input_file, output_file):
    regex_content = re.compile(r'content:"([^"]+)"')
    
    unique_patterns = set()
    total_rules_parsed = 0

    print(f"Reading of {input_file}")
    
    try:
        with open(input_file, 'r', encoding='utf-8', errors='ignore') as f:
            for line in f:
                line = line.strip()
                
                if not line or line.startswith('#'):
                    continue
                
                total_rules_parsed += 1
                
                matches = regex_content.findall(line)
                
                for m in matches:
                    if len(m) < 3:
                        continue
                        
                    if '|' in m:
                        continue 
                        
                    unique_patterns.add(m)
                    
    except FileNotFoundError:
        print(f"Error: the file {input_file} is not found.")
        return

    print(f"Writting of {output_file}")
    with open(output_file, 'w', encoding='utf-8') as f:
        for p in unique_patterns:
            f.write(p + '\n')

    print("-" * 30)
    print(f"Rules analysed : {total_rules_parsed}")
    print(f"Unique pattern found: {len(unique_patterns)}")
    print(f"File generated : {output_file}")

if __name__ == "__main__":
    extract_suricata_patterns("suricata.rules", "patterns.txt")