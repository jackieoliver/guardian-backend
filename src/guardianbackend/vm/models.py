from pydantic import BaseModel


class VmRecord(BaseModel):
    vm_id: str
    zone: str
    public_ip: str
    ssh_login_user: str
    role: str
