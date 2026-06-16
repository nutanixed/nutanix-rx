import os
from ldap3 import Server, Connection, ALL
from dotenv import load_dotenv

load_dotenv()

LDAP_SERVER = os.getenv('LDAP_SERVER')
LDAP_ADMIN_DN = os.getenv('LDAP_ADMIN_DN')
LDAP_ADMIN_PASSWORD = os.getenv('LDAP_ADMIN_PASS')
LDAP_USER_SEARCH_BASE = os.getenv('LDAP_USER_SEARCH_BASE')
LDAP_USER_ATTRIBUTE = os.getenv('LDAP_USER_ATTRIBUTE')

print(f"Testing LDAP connection to {LDAP_SERVER}...")
print(f"Admin DN: {LDAP_ADMIN_DN}")

try:
    server = Server(LDAP_SERVER, get_info=ALL)
    conn = Connection(server, user=LDAP_ADMIN_DN, password=LDAP_ADMIN_PASSWORD, authentication='SIMPLE')
    if not conn.bind():
        print(f"FAIL: Admin bind failed: {conn.result}")
    else:
        print("SUCCESS: Admin bind successful.")
        
        test_user = "ekeiper"
        search_filter = f"({LDAP_USER_ATTRIBUTE}={test_user})"
        print(f"Searching for user: {test_user} with filter: {search_filter} in {LDAP_USER_SEARCH_BASE}")
        
        conn.search(LDAP_USER_SEARCH_BASE, search_filter, attributes=['*'])
        if conn.entries:
            print(f"SUCCESS: User {test_user} found: {conn.entries[0].entry_dn}")
        else:
            print(f"FAIL: User {test_user} not found.")
            
        conn.unbind()
except Exception as e:
    print(f"ERROR: {str(e)}")
