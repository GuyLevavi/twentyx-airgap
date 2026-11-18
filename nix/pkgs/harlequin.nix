# harlequin over postgres and sqlite, without the cloud.
#
# nixpkgs' build is ~1 GB, and a fifth of that is SDKs for clouds this
# network cannot reach: the BigQuery adapter, plus google-cloud-cpp, grpc,
# Azure and AWS linked into arrow-cpp so pyarrow can read gs:// and s3://.
# harlequin only uses pyarrow as an in-memory table format (through
# textual-fastdatatable), so all of it goes.
#
# The price is a local build of arrow-cpp and pyarrow on the connected side,
# since no binary cache has this variant. Inside the gap it is a store path
# like any other.
{
  python3,
  arrow-cpp,
  harlequin,
}:
let
  arrow-slim = arrow-cpp.override {
    enableFlight = false;
    enableS3 = false;
    enableGcs = false;
    enableAzure = false;
  };

  python = python3.override {
    self = python;
    packageOverrides = _: super: {
      pyarrow = (super.pyarrow.override { arrow-cpp = arrow-slim; }).overridePythonAttrs (old: {
        # Flight is gone, so its module can no longer import.
        pythonImportsCheck = builtins.filter (m: m != "pyarrow.flight") old.pythonImportsCheck;
        # Its flight tests skip themselves; this one imports flight at
        # collection time and takes the whole session down instead.
        disabledTestPaths = (old.disabledTestPaths or [ ]) ++ [ "pyarrow/tests/test_flight_async.py" ];
      });
    };
  };
in
harlequin.override {
  python3Packages = python.pkgs;
  withBigQueryAdapter = false;
}
