import binascii

def generate_orange_option90(fti_username):
    # Ensure username is stripped of accidental whitespaces
    username = fti_username.strip()
    
    # 22-byte fixed Orange prefix header
    header_hex = "00000000000000000000001a093a0c"
    
    # Calculate the length of the fti/xxxxxxx string in bytes
    username_bytes = username.encode('utf-8')
    username_length_hex = f"{len(username_bytes):02x}"
    
    # Convert the username string to hex
    username_hex = binascii.hexlify(username_bytes).decode('utf-8')
    
    # Combine everything into a continuous hex string
    raw_hex = header_hex + username_length_hex + username_hex
    
    # Format with colons for OpenWrt/LuCI compatibility
    formatted_hex = ":".join(raw_hex[i:i+2] for i in range(0, len(raw_hex), 2))
    
    print("=" * 50)
    print(f"Orange Username: {username}")
    print("=" * 50)
    print(f"Raw Hex (For some clients):\n{raw_hex}\n")
    print(f"Colon-Separated Hex (For OpenWrt /etc/config/network):\n{formatted_hex}")
    print("=" * 50)
    return formatted_hex

# Replace with your actual fti/ identifier from your Orange contract
orange_id = "fti/x2abcde" 
generate_orange_option90(orange_id)

