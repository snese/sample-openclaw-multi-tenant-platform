use tenant_operator::controller::Tenant;
use kube::CustomResourceExt;

fn main() {
    print!(
        "{}",
        serde_yaml::to_string(&Tenant::crd()).unwrap()
    );
}
