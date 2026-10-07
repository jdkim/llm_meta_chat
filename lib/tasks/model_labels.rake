# Fills in `model_label` on turns written before the column existed.
#
# Only touches rows where it is blank, so it never overwrites a label captured
# at write time, and it is safe to re-run. Models missing from the data file are
# left alone: they keep resolving against the live catalog, which is the honest
# answer when no label was ever recorded.
#
#   bin/rails model_labels:backfill            # apply
#   DRY_RUN=1 bin/rails model_labels:backfill  # report only
namespace :model_labels do
  desc "Backfill PromptExecution#model_label from db/historic_model_labels.yml"
  task backfill: :environment do
    path = Rails.root.join("db/historic_model_labels.yml")
    abort "missing #{path}" unless File.exist?(path)

    labels  = YAML.load_file(path).fetch("labels")
    dry_run = ENV["DRY_RUN"].present?
    scope   = PromptNavigator::PromptExecution.where(model_label: [ nil, "" ])
                                              .where.not(model: [ nil, "" ])

    puts "#{labels.size} known labels; #{scope.count} turns without one"

    filled = 0
    unknown = Hash.new(0)
    scope.group(:model).count.sort_by { |_, n| -n }.each do |model, count|
      label = labels[model]
      if label.nil?
        unknown[model] = count
        next
      end
      puts format("  %-28s %-38s %4d turns%s", model, label, count, dry_run ? " (dry run)" : "")
      scope.where(model: model).update_all(model_label: label) unless dry_run
      filled += count
    end

    puts dry_run ? "would fill #{filled} turns" : "filled #{filled} turns"
    unless unknown.empty?
      puts "left alone — no label was ever recorded for these, so they keep the platform fallback:"
      unknown.sort_by { |_, n| -n }.each { |m, n| puts format("  %-28s %4d turns", m, n) }
    end
  end
end
