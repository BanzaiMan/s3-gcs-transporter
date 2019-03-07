require 'aws-sdk'
require 'google/cloud/storage'
require 'smarter_csv'
require 'optparse'
require 'pathname'
require 'fileutils'
require 'logger'

def logger
  @logger ||= Logger.new $stderr
  @logger.level = Logger::WARN
end

def options
  @options ||= {
    s3_region: 'us-east-1',
  }
end

parser = OptionParser.new do |opts|
  opts.banner = "Usage: #{$0} [options]"

  opts.on("-v", "--[no-]verbose", "Run verbosely") do |v|
    options[:verbose] = v
  end

  opts.on("--s3-region=MANDATORY", "S3 region") do |s3_region|
    options[:s3_region] = s3_region
  end

  opts.on("--s3-creds-csv=MANDATORY", "csv file containing S3 credentials, as downloaded from AWS") do |csv_file|
    options[:s3_creds_csv] = csv_file
  end

  opts.on("--gcs-region=MANDATORY", "GCS region") do |gcs_region|
    options[:gcs_region] = gcs_region
  end

  opts.on("--gcs-creds-json=MANDATORY", "JSON file containing GCS credentials, as downloaded from GCP") do |json_file|
    options[:gcs_creds_json] = json_file
  end

  opts.on("--gcs-project-id=MANDATORY", "GCS project ID") do |proj_id|
    options[:gcs_project_id] = proj_id
  end

  opts.on("--s3-bucket=MANDATORY", "Bucket to copy from (on S3)") do |bucket|
    options[:s3_bucket] = bucket
  end

  opts.on("--s3-prefix=MANDATORY", "Bucket prefix for S3") do |prefix|
    options[:s3_prefix] = prefix
  end

  opts.on("--gcs-bucket=MANDATORY", "Bucket to copy to (on GCS)") do |bucket|
    options[:gcs_bucket] = bucket
  end

  opts.on("--gcs-prefix=MANDATORY", "Bucket prefix for GCS") do |prefix|
    options[:gcs_prefix] = prefix
  end

  opts.on("--log-level=MANDATORY", "Log level") do |level|
    logger.level = Logger.const_get(level.upcase)
  end
end

parser.parse!

Google::Apis.logger = logger
logger.level = Logger::DEBUG if options[:verbose]
logger.debug options.inspect

def s3
  @s3 ||= Aws::S3::Resource.new(
    region: options[:s3_region] || 'us-east-1',
    credentials: Aws::Credentials.new(s3_creds[:access_key_id], s3_creds[:secret_access_key])
  )
end

def s3_creds
  return @s3_creds if @s3_creds

  data = SmarterCSV.process(options[:s3_creds_csv])
  @s3_creds = data.first
end

def gcs
  @gcs ||= Google::Cloud::Storage.new(
    project_id: options[:gcs_project_id],
    credentials: options[:gcs_creds_json]
  )
end

def main
  s3_bucket  = s3.bucket(options[:s3_bucket])
  gcs_bucket = gcs.bucket(options[:gcs_bucket])

  s3_bucket.objects.each do |obj_summary|
    obj_key = obj_summary.key
    unless obj_summary.size > 0
      logger.info "Skipping blank file #{obj_key}"
      next
    end
    unless obj_key.start_with?(options[:s3_prefix])
      logger.info "Skipping #{obj_key} because it does not match prefix #{options[:s3_prefix]}"
      next
    end

    pn = Pathname.new(obj_key)
    logger.info "Processing #{obj_key}"
    logger.info "Downloading #{obj_key}"

    local_file = File.basename(pn)

    unless obj_summary.download_file(local_file)
      logger.warn "Failed to download #{obj_key}"
      next
    end

    # Upload to GCS
    gcs_obj_key = obj_key.sub(options[:s3_prefix], options[:gcs_prefix])
    logger.debug "local_file: #{local_file}"
    logger.debug "gcs_obj_key: #{gcs_obj_key}"
    if gcs_bucket.create_file(local_file, gcs_obj_key, acl: 'publicRead')
      logger.info "Uploaded #{gcs_obj_key}"
      FileUtils.rm_f(local_file)
    end
  end
end

main